import Foundation

/// Tells a Mac carried off in a bag from one closed on a desk. Nothing says "bag" directly, so it adds up
/// weighted signals, and only with the lid closed on battery with no external display: anything plugged in
/// means a desk. Motion only shows that the Mac is being carried, and a bag set down looks like a desk to
/// the accelerometer, so carrying is remembered until the lid opens again. Heat is not scored here: it has
/// the last word in Power.pause, at a lower threshold the likelier a bag is.
struct BagDetector {
    struct Reading {
        var lidClosed: Bool
        var onBattery: Bool
        var externalDisplay: Bool
        /// When the Mac was last found being carried, see MotionWindow.
        var carriedAt: Date?
        /// The network's router, nil without a network.
        var router: String?
    }

    enum Level: Comparable { case none, careful, sleep }

    static let carriedWeight = 50
    static let networkWeight = 30
    /// Carried is careful; carried off to another network, or off any network, is a bag.
    static let carefulScore = 50
    static let sleepScore = 80
    /// Carrying only counts once it goes on this long after the lid closed, so a walk to a meeting room,
    /// even one that switches the office network, never counts. A commute does.
    static let grace: TimeInterval = 5 * 60

    private var closedAt: Date?
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
            (closedAt, routerAtClose, carriedAt, score) = (nil, nil, nil, 0)
            return level
        }
        if closedAt == nil {
            closedAt = now
            routerAtClose = reading.router
        }
        if let at = reading.carriedAt, at >= closedAt! + Self.grace { carriedAt = max(at, carriedAt ?? at) }

        score = 0
        if carriedAt != nil { score += Self.carriedWeight }
        if let routerAtClose, reading.router != routerAtClose { score += Self.networkWeight }
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
    // Running sums rather than the samples: they arrive 100 times a second.
    private var count = 0.0, sum = 0.0, squares = 0.0

    /// Adds one acceleration magnitude, in g.
    mutating func add(_ magnitude: Double) {
        count += 1
        sum += magnitude
        squares += magnitude * magnitude
    }

    /// Closes the current second and says whether the Mac is being carried.
    mutating func tick() -> Bool {
        let mean = sum / max(count, 1)
        let deviation = max(squares / max(count, 1) - mean * mean, 0).squareRoot()
        (count, sum, squares) = (0, 0, 0)
        seconds.append(deviation > Self.movingDeviation)
        if seconds.count > Self.length { seconds.removeFirst() }
        return seconds.filter { $0 }.count >= Self.movingSeconds
    }
}
