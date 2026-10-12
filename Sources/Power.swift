import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac awake. A power assertion is enough for a locked Mac, but closing the lid sleeps the
/// Mac regardless of assertions, so for that Insomnia sets the system's SleepDisabled flag with pmset.
/// A sudoers rule, installed once with an administrator password, lets it do that and nothing else.
@MainActor
final class Power {
    enum Pause { case battery, heat, bag }

    private static let rule = "/etc/sudoers.d/insomnia"
    private static let lowBattery = 10
    private static let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

    private let defaults: UserDefaults
    private var activity: NSObjectProtocol?
    private var watchdog: Process?
    private var lifeline: Pipe?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Covers a crash the watchdog could not clean up after, such as a logout mid-session.
        if defaults.bool(forKey: "sleepDisabled") { setSleepDisabled(false) }
    }

    var canKeepLidClosed: Bool { FileManager.default.fileExists(atPath: Self.rule) }

    func hold() {
        guard activity == nil else { return }
        // Prevents idle sleep and sudden termination, and keeps App Nap from stretching the agent checks.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Insomnia is keeping your Mac awake")
        holdLid()
    }

    func release() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        if let watchdog {
            watchdog.terminate()
            self.watchdog = nil
            lifeline = nil
            setSleepDisabled(false)
        }
        // With the lid already shut nothing else would put the Mac to sleep, say in a bag.
        if Self.rootDomainFlag("AppleClamshellState") && Self.rootDomainFlag("AppleClamshellCausesSleep") {
            let port = IOPMFindPowerManagement(kIOMainPortDefault)
            IOPMSleepSystem(port)
            IOServiceClose(port)
        }
    }

    /// Puts SleepDisabled back if something else, such as another keep-awake app, switched it off underneath.
    func reassert() {
        guard watchdog != nil, !Self.rootDomainFlag("SleepDisabled") else { return }
        setSleepDisabled(true)
    }

    /// Shows the system administrator prompt and installs the sudoers rule.
    func allowClosedLid() {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else { return }
        let entry = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let script = "t=$(/usr/bin/mktemp) && echo '\(entry)' > $t && /usr/sbin/visudo -cqf $t && "
            + "/usr/bin/install -m 0440 -o root -g wheel $t \(Self.rule); s=$?; /bin/rm -f $t; exit $s"
        let prompt = "Insomnia needs your permission once to keep your Mac awake with the lid closed."
        NSApp.activate()
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(script)\" with prompt \"\(prompt)\" with administrator privileges")?
            .executeAndReturnError(&error)
        holdLid()
    }

    static func pause(leaving: Bool, lidClosedUndocked: Bool) -> Pause? {
        pause(thermal: ProcessInfo.processInfo.thermalState, batteryLow: batteryLow, leaving: leaving,
              lidClosedUndocked: lidClosedUndocked)
    }

    /// Leaving with the Mac lets it sleep. Heat has the last word either way: critical anywhere, and with the bag
    /// safeguard on, serious with the lid closed away from a dock, for the bags the detector misses. With it off,
    /// Insomnia behaves as it always has.
    nonisolated static func pause(thermal: ProcessInfo.ThermalState, batteryLow: Bool, leaving: Bool,
                                  lidClosedUndocked: Bool) -> Pause? {
        if leaving { return .bag }
        if thermal.rawValue >= (lidClosedUndocked ? ProcessInfo.ThermalState.serious : .critical).rawValue { return .heat }
        return batteryLow ? .battery : nil
    }

    /// With the bag safeguard on, a pause for heat or a bag with the lid closed holds until the lid opens or a display
    /// is plugged in, so a wake after cooling down never holds the Mac awake in the bag again.
    nonisolated static func latch(_ current: Pause?, latched: Pause?, lidClosedUndocked: Bool, watchesForBag: Bool) -> Pause? {
        guard watchesForBag, lidClosedUndocked else { return nil }
        return latched ?? (current == .heat || current == .bag ? current : nil)
    }

    private static var batteryLow: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let level = description[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0 else { continue }
            if level * 100 / capacity <= lowBattery { return true }
        }
        return false
    }

    private func holdLid() {
        guard activity != nil, watchdog == nil, canKeepLidClosed, setSleepDisabled(true) else { return }
        // Restores sleep if Insomnia dies without cleaning up, so a crash never cooks a Mac in a bag.
        // It sleeps in a read from a pipe only Insomnia holds open, which ends the moment Insomnia is gone.
        let lifeline = Pipe()
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", "read _; exec /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"]
        watchdog.standardInput = lifeline
        try? watchdog.run()
        self.watchdog = watchdog
        self.lifeline = lifeline
    }

    @discardableResult
    private func setSleepDisabled(_ disabled: Bool) -> Bool {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        pmset.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        pmset.standardOutput = FileHandle.nullDevice
        pmset.standardError = FileHandle.nullDevice
        // waitUntilExit() would spin the run loop and let a timer re-enter mid-change.
        let exited = DispatchSemaphore(value: 0)
        pmset.terminationHandler = { _ in exited.signal() }
        guard (try? pmset.run()) != nil else { return false }
        exited.wait()
        guard pmset.terminationStatus == 0 else { return false }
        defaults.set(disabled, forKey: "sleepDisabled")
        return true
    }

    private static func rootDomainFlag(_ key: String) -> Bool {
        IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }
}
