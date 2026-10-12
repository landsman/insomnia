/// What each sign of leaving with the Mac is worth to BagDetector. Tune them here: BagScenarioTests replays the
/// use cases from docs/bag-detection.md and fails when a change makes one of them come out wrong.
struct BagWeights {
    /// Carried after the lid closed, by how long. A carry inside the office is short, the way home is long.
    var carried: [(minutes: Double, points: Int)]
    /// Lost the network the lid closed on, or moved to another, for a minute. Never on a hotspot.
    var leftNetwork: Int
    /// Standing on an edge, as in a backpack, rather than lying flat.
    var onEdge: Int
    /// Warming up with the lid closed: it cools in a hand, not in a bag.
    var warm: Int
    /// The score at which the Mac goes to sleep.
    var sleepAt: Int

    static let standard = BagWeights(
        carried: [(8, 60), (5, 45), (3, 30), (1, 15)],
        leftNetwork: 30,
        onEdge: 15,
        warm: 20,
        sleepAt: 70
    )
}
