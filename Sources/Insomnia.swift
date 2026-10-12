import AppKit
import IOKit.ps

@MainActor
final class Insomnia {
    /// "agents" keeps the setting saved by version 1.0, when agents were the only work Insomnia knew.
    enum Mode: String { case working = "agents", always }

    /// How long the Mac stays up after the last work goes quiet, enough to bridge a pause between steps.
    static let grace: TimeInterval = 5 * 60

    var isOn: Bool {
        didSet { defaults.set(isOn, forKey: "on"); refresh(); rescanSoon() }
    }
    var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: "mode"); refresh(); rescanSoon() }
    }
    /// Apps, by bundle identifier, that count as work whenever they are open, busy or not.
    var chosenApps: [String] {
        didSet { defaults.set(chosenApps, forKey: "chosenApps"); refresh() }
    }
    /// The menu watches work while it is open, even when Insomnia is off.
    var isWatching = false {
        didSet { refresh(); rescanSoon() }
    }
    var onChange: () -> Void = {}
    #if DEBUG
    /// Snapshots show this instead of the work going on on this Mac.
    var demo: (agents: [Agent], apps: [BusyApp], upload: Double)?
    #endif

    private(set) var agents: [Agent] = []
    private(set) var apps: [BusyApp] = []
    /// Bytes per second, once they add up to an upload.
    private(set) var upload: Double = 0
    private(set) var pause: Power.Pause?
    private(set) var awakeSince: Date?
    private(set) var lastWork: Date?

    let power: Power
    private let agentMonitor = AgentMonitor()
    private let appMonitor = AppMonitor()
    private let defaults: UserDefaults
    private var timer: Timer?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        power = Power(defaults: defaults)
        isOn = defaults.bool(forKey: "on")
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .working
        chosenApps = defaults.stringArray(forKey: "chosenApps") ?? []
        refresh()
        rescanSoon()

        // Battery and heat are pushed by the system, so only work ever needs polling.
        let powerSource = IOPSNotificationCreateRunLoopSource({ context in
            MainActor.assumeIsolated { Unmanaged<Insomnia>.fromOpaque(context!).takeUnretainedValue().refresh() }
        }, Unmanaged.passUnretained(self).toOpaque()).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
        _ = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // A chosen app counts from the moment it opens, not from the next poll.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            _ = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, self.mode == .working, self.chosenApps.contains(app?.bundleIdentifier ?? "") else { return }
                    self.refresh()
                }
            }
        }
    }

    var isWorking: Bool {
        agents.contains(where: \.isWorking) || !apps.isEmpty || upload > 0
    }

    var sleepsAt: Date? {
        guard mode == .working, awakeSince != nil, !isWorking, let lastWork else { return nil }
        return lastWork.addingTimeInterval(Self.grace)
    }

    func refresh() {
        let now = Date.now
        if mode == .working && (isOn || isWatching) {
            let processes = Processes.current()
            agents = agentMonitor.scan(processes, now: now)
            apps = appMonitor.scan(processes, ignoring: agentMonitor.involved, now: now)
            for app in NSWorkspace.shared.runningApplications where chosenApps.contains(app.bundleIdentifier ?? "") {
                guard let bundle = app.bundleURL?.path, !apps.contains(where: { $0.bundle == bundle }) else { continue }
                apps.append(BusyApp(name: app.localizedName ?? FileManager.default.displayName(atPath: bundle), bundle: bundle))
            }
            let rate = appMonitor.uploadRate(now: now)
            upload = rate >= AppMonitor.uploadBytesPerSecond ? rate : 0
        } else {
            (agents, apps, upload) = ([], [], 0)
        }
        #if DEBUG
        if let demo { (agents, apps, upload) = demo }
        #endif
        if isWorking { lastWork = now }
        pause = isOn ? Power.pause : nil

        let recentWork = lastWork.map { now.timeIntervalSince($0) < Self.grace } ?? false
        let awake = isOn && pause == nil && (mode == .always || recentWork)
        if awake, awakeSince == nil {
            awakeSince = now
            power.hold()
        } else if !awake, awakeSince != nil {
            awakeSince = nil
            power.release()
        } else if awake {
            power.reassert()
        }

        schedule()
        onChange()
    }

    /// Work shows as change between two scans, so a first look gets a second one right away
    /// rather than at the next poll, in case the lid is about to close.
    private func rescanSoon() {
        guard mode == .working, isOn || isWatching else { return }
        let rescan = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(rescan, forMode: .common)
    }

    /// Polls for work only while Insomnia relies on it: every 10 s to catch it starting, every 30 s
    /// while it runs, since the grace period makes noticing the end later harmless. Livelier while the menu shows it.
    private func schedule() {
        let interval: TimeInterval? = isWatching ? 3 : isOn && mode == .working ? (awakeSince == nil ? 10 : 30) : nil
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Lets macOS bundle the wakeup with others.
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func shutDown() {
        timer?.invalidate()
        power.release()
    }
}
