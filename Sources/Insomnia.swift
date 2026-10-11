import AppKit

@MainActor
final class Insomnia {
    enum Mode: String { case agents, always }

    /// How long the Mac stays up after the last agent goes quiet, enough to bridge a pause between turns.
    static let grace: TimeInterval = 5 * 60

    var isOn: Bool {
        didSet { defaults.set(isOn, forKey: "on"); refresh() }
    }
    var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: "mode"); refresh() }
    }
    /// The menu watches agents while it is open, even when Insomnia is off.
    var isWatching = false {
        didSet {
            refresh()
            guard isWatching else { return }
            // Work shows as change between two scans, so a menu opened cold takes a second look right away.
            let rescan = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(rescan, forMode: .common)
        }
    }
    var onChange: () -> Void = {}

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
    }

    var sleepsAt: Date? {
        guard mode == .agents, awakeSince != nil, !agents.contains(where: \.isWorking), let lastWork else { return nil }
        return lastWork.addingTimeInterval(Self.grace)
    }

    func refresh() {
        let now = Date.now
        agents = mode == .agents && (isOn || isWatching) ? monitor.scan(now: now) : []
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
        }

        if isOn || isWatching {
            if timer == nil {
                let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
        onChange()
    }

    func shutDown() {
        timer?.invalidate()
        power.release()
    }
}
