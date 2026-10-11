import AppKit
import IOKit.ps

@MainActor
final class Insomnia {
    enum Mode: String { case agents, always }

    /// How long the Mac stays up after the last agent goes quiet, enough to bridge a pause between turns.
    static let grace: TimeInterval = 5 * 60

    var isOn: Bool {
        didSet { defaults.set(isOn, forKey: "on"); refresh(); rescanSoon() }
    }
    var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: "mode"); refresh(); rescanSoon() }
    }
    /// The menu watches agents while it is open, even when Insomnia is off.
    var isWatching = false {
        didSet { refresh(); rescanSoon() }
    }
    var onChange: () -> Void = {}
    #if DEBUG
    /// Snapshots show these instead of the agents running on this Mac.
    var demoAgents: [Agent]?
    #endif

    private(set) var agents: [Agent] = []
    private(set) var pause: Power.Pause?
    private(set) var awakeSince: Date?
    private(set) var lastWork: Date?

    let power: Power
    private let monitor = AgentMonitor()
    private let defaults: UserDefaults
    private var timer: Timer?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        power = Power(defaults: defaults)
        isOn = defaults.bool(forKey: "on")
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .agents
        refresh()
        rescanSoon()

        // Battery and heat are pushed by the system, so only agents ever need polling.
        let powerSource = IOPSNotificationCreateRunLoopSource({ context in
            MainActor.assumeIsolated { Unmanaged<Insomnia>.fromOpaque(context!).takeUnretainedValue().refresh() }
        }, Unmanaged.passUnretained(self).toOpaque()).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
        _ = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var sleepsAt: Date? {
        guard mode == .agents, awakeSince != nil, !agents.contains(where: \.isWorking), let lastWork else { return nil }
        return lastWork.addingTimeInterval(Self.grace)
    }

    func refresh() {
        let now = Date.now
        agents = mode == .agents && (isOn || isWatching) ? monitor.scan(now: now) : []
        #if DEBUG
        if let demoAgents { agents = demoAgents }
        #endif
        if agents.contains(where: \.isWorking) { lastWork = now }
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

    /// Work shows as change between two scans, so a first look at agents gets a second one right away
    /// rather than at the next poll, in case the lid is about to close.
    private func rescanSoon() {
        guard mode == .agents, isOn || isWatching else { return }
        let rescan = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(rescan, forMode: .common)
    }

    /// Polls agents only while Insomnia relies on them: every 10 s to catch them starting, every 30 s
    /// while they work, since the grace period makes noticing the end later harmless. Livelier while the menu shows them.
    private func schedule() {
        let interval: TimeInterval? = isWatching ? 3 : isOn && mode == .agents ? (awakeSince == nil ? 10 : 30) : nil
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
