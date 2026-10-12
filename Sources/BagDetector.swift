import Foundation

/// Tells a Mac carried off in a bag from one closed on a desk. Nothing says "bag" directly, so it adds up
/// weighted signals, and only with the lid closed on battery with no external display: anything plugged in
/// means a desk. Motion only shows that the Mac is being carried, and a bag set down looks like a desk to
/// the accelerometer, so carrying is remembered until the lid opens again.
struct BagDetector {
    struct Reading {
        var lidClosed: Bool
        var onBattery: Bool
        var externalDisplay: Bool
        /// When the Mac was last found being carried, see MotionWindow.
        var carriedAt: Date?
        /// The network's router, nil without a network.
        var router: String?
        var thermal: ProcessInfo.ThermalState
    }

    enum Level: Comparable { case none, careful, sleep }

    static let carriedWeight = 50
    static let networkWeight = 30
    static let heatWeight = 20
    /// Carrying it is enough to be careful; carrying plus a new network or heat puts it to sleep.
    static let carefulScore = 50
    static let sleepScore = 80
    /// A Mac carried half an hour ago with the lid shut ever since is still taken for one in a bag.
    static let carriedMemory: TimeInterval = 30 * 60

    private var watching = false
    /// The router when the lid closed. nil when there was no network then, which leaves the network out.
    private var routerAtClose: String?
    private var carriedAt: Date?

    private(set) var score = 0

    var level: Level {
        score >= Self.sleepScore ? .sleep : score >= Self.carefulScore ? .careful : .none
    }

    @discardableResult
    mutating func update(_ reading: Reading, now: Date = .now) -> Level {
        guard reading.lidClosed, reading.onBattery, !reading.externalDisplay else {
            (watching, routerAtClose, carriedAt, score) = (false, nil, nil, 0)
            return level
        }
        if !watching {
            watching = true
            routerAtClose = reading.router
        }
        if let at = reading.carriedAt { carriedAt = max(at, carriedAt ?? at) }

        score = 0
        if let carriedAt, now.timeIntervalSince(carriedAt) < Self.carriedMemory { score += Self.carriedWeight }
        if let routerAtClose, reading.router != routerAtClose { score += Self.networkWeight }
        if reading.thermal.rawValue >= ProcessInfo.ThermalState.fair.rawValue { score += Self.heatWeight }
        return level
    }
}

/// Turns the accelerometer into "being carried", one second at a time. Measured on a walk with the lid closed:
/// a Mac at rest varies by 0.0006 g, one in a carried bag by 0.11 g in a typical second, and walking left
/// quiet gaps of up to 11 s. So half of the last 30 seconds moving is carrying, and a lift from desk to sofa is not.
struct MotionWindow {
    static let movingDeviation = 0.02
    static let length = 30
    static let movingSeconds = 15

    private var seconds: [Bool] = []
    private var samples: [Double] = []

    /// Adds one acceleration magnitude, in g.
    mutating func add(_ magnitude: Double) {
        samples.append(magnitude)
    }

    /// Closes the current second and says whether the Mac is being carried.
    mutating func tick() -> Bool {
        let count = Double(samples.count)
        let mean = samples.reduce(0, +) / max(count, 1)
        let deviation = (samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / max(count, 1)).squareRoot()
        samples.removeAll(keepingCapacity: true)
        seconds.append(deviation > Self.movingDeviation)
        if seconds.count > Self.length { seconds.removeFirst() }
        return seconds.filter { $0 }.count >= Self.movingSeconds
    }
}
