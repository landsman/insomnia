import Foundation

/// Tells leaving with the Mac in a bag from carrying it to a meeting room, both with the lid closed and no
/// external display. No single sign decides, since each fails somewhere: a hotspot never loses its network,
/// a long walk across a campus is still the office. So weighted signs add up, from BagWeights, and the Mac sleeps
/// at its sleepAt.
/// docs/bag-detection.md has the reasoning and the scenarios, which BagScenarioTests replays.
struct BagDetector {
    struct Reading {
        var lidClosed: Bool
        var externalDisplay: Bool
        /// Seconds the Mac has been carried since the motion sensor started, see MotionWindow.
        var carriedSeconds: Int
        /// Standing rather than lying, as in a backpack.
        var onEdge: Bool
        /// The network's router, nil without a network.
        var router: String?
        /// A phone's hotspot, which travels along and so never shows leaving.
        var hotspot: Bool
        var thermal: ProcessInfo.ThermalState
    }

    /// Roaming between access points drops the network for seconds, leaving the building for good.
    static let networkChangedFor: TimeInterval = 60

    private var closed = false
    private var routerAtClose: String?
    private var closedOnHotspot = false
    private var changedSince: Date?
    private var carried: TimeInterval = 0
    private var lastCarriedSeconds = 0

    let weights: BagWeights
    private(set) var score = 0
    var isLeaving: Bool { score >= weights.sleepAt }

    init(weights: BagWeights = .standard) {
        self.weights = weights
    }

    @discardableResult
    mutating func update(_ reading: Reading, now: Date = .now) -> Bool {
        guard reading.lidClosed, !reading.externalDisplay else {
            self = BagDetector(weights: weights)
            return false
        }
        if !closed {
            closed = true
            routerAtClose = reading.router
            closedOnHotspot = reading.hotspot
        }
        // The sensor's count starts over whenever it does; carrying is remembered until the lid opens,
        // since a bag set down reads like a desk to the accelerometer.
        carried += TimeInterval(reading.carriedSeconds >= lastCarriedSeconds ? reading.carriedSeconds - lastCarriedSeconds : reading.carriedSeconds)
        lastCarriedSeconds = reading.carriedSeconds
        changedSince = reading.router == routerAtClose ? nil : changedSince ?? now

        score = weights.carried.filter { carried >= $0.minutes * 60 }.map(\.points).max() ?? 0
        if let changedSince, routerAtClose != nil, !closedOnHotspot, now.timeIntervalSince(changedSince) >= Self.networkChangedFor {
            score += weights.leftNetwork
        }
        if reading.onEdge { score += weights.onEdge }
        if reading.thermal.rawValue >= ProcessInfo.ThermalState.fair.rawValue { score += weights.warm }
        return isLeaving
    }
}

/// Turns the accelerometer into "being carried", one second at a time. Measured on a walk with the lid closed:
/// a Mac at rest varies by 0.0006 g, one in a carried bag by 0.11 g in a typical second, and walking left
/// quiet gaps of up to 11 s. So half of the last 30 seconds moving is carrying, and a lift from desk to sofa is not.
struct MotionWindow {
    static let movingDeviation = 0.02
    static let length = 30
    static let movingSeconds = 15
    /// Gravity mostly off the Z axis: the Mac stands on an edge. ponytail: a guess until a bag and a hand are measured.
    static let edgeRatio = 0.5

    private var seconds: [Bool] = []
    // Running sums rather than the samples: they arrive 100 times a second.
    private var count = 0.0, sum = 0.0, squares = 0.0, z = 0.0
    private(set) var onEdge = false

    /// Adds one acceleration sample, in g.
    mutating func add(x: Double, y: Double, z: Double) {
        let magnitude = (x * x + y * y + z * z).squareRoot()
        count += 1
        sum += magnitude
        squares += magnitude * magnitude
        self.z += abs(z)
    }

    /// Closes the current second and says whether the Mac is being carried.
    mutating func tick() -> Bool {
        let mean = sum / max(count, 1)
        let deviation = max(squares / max(count, 1) - mean * mean, 0).squareRoot()
        if count > 0 { onEdge = z / count < Self.edgeRatio * mean }
        (count, sum, squares, z) = (0, 0, 0, 0)
        seconds.append(deviation > Self.movingDeviation)
        if seconds.count > Self.length { seconds.removeFirst() }
        return seconds.filter { $0 }.count >= Self.movingSeconds
    }
}
