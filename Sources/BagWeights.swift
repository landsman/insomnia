/// What each sign of leaving with the Mac is worth to BagDetector. Tune them here: BagScenarioTests replays the
/// use cases from docs/bag-detection.md and fails when a change makes one of them come out wrong.
struct BagWeights {
    /// The latest trip, carried for so many minutes. A carry inside the office is short, the way home is long.
    var carried: [(minutes: Double, points: Int)]
    /// Off the network the lid closed on for a minute, or onto a phone's hotspot.
    var lostNetwork: Int
    /// On another network for a minute, as in a meeting room in another building.
    var otherNetwork: Int
    /// Standing on an edge, as in a backpack, rather than lying flat.
    var onEdge: Int
    /// Warming up with the lid closed: it cools in a hand, not in a bag.
    var warm: Int
    /// The score at which the Mac goes to sleep.
    var sleepAt: Int

    static let standard = BagWeights(
        carried: [(1, 15), (3, 30), (5, 45), (8, 60)],
        lostNetwork: 40,
        otherNetwork: 15,
        onEdge: 15,
        warm: 20,
        sleepAt: 70
    )
}
