import Foundation
import Testing
@testable import Insomnia

private let closed = Date(timeIntervalSince1970: 1_000_000)
private let afterGrace = closed + BagDetector.grace
private let home = "192.168.0.1"

/// A Mac closed on battery at home and at rest, unless a test says otherwise.
private func reading(lidClosed: Bool = true, onBattery: Bool = true, externalDisplay: Bool = false,
                     carriedAt: Date? = nil, router: String? = home) -> BagDetector.Reading {
    .init(lidClosed: lidClosed, onBattery: onBattery, externalDisplay: externalDisplay, carriedAt: carriedAt, router: router)
}

/// A detector that saw the lid close at `closed`.
private func detector() -> BagDetector {
    var detector = BagDetector()
    detector.update(reading(), now: closed)
    return detector
}

@Suite struct BagDetectorTests {
    @Test func closedAtRestOnADeskIsNoBag() {
        var detector = detector()
        #expect(detector.update(reading(), now: closed + 3600) == .none)
        #expect(detector.score == 0)
    }

    /// Walking to a meeting room, even onto another office network, sleeps nothing.
    @Test func carryingAroundTheOfficeWithinTheGraceDoesNotCount() {
        var detector = detector()
        detector.update(reading(carriedAt: closed + 60), now: closed + 60)
        detector.update(reading(carriedAt: closed + 180, router: "10.1.2.1"), now: closed + 180)
        #expect(detector.update(reading(router: "10.1.2.1"), now: closed + 3600) == .none)
        #expect(detector.score == BagDetector.networkWeight)
    }

    @Test func carryingOnPastTheGraceMakesItCareful() {
        var detector = detector()
        #expect(detector.update(reading(carriedAt: afterGrace + 1), now: afterGrace + 1) == .careful)
    }

    @Test func carryingOffToAnotherNetworkPutsItToSleep() {
        var detector = detector()
        detector.update(reading(carriedAt: afterGrace + 10), now: afterGrace + 10)
        #expect(detector.update(reading(router: "10.0.0.1"), now: afterGrace + 300) == .sleep)
    }

    @Test func losingTheNetworkCountsAsLeaving() {
        var detector = detector()
        #expect(detector.update(reading(carriedAt: afterGrace + 10, router: nil), now: afterGrace + 10) == .sleep)
    }

    @Test func aNetworkChangeWithoutCarryingIsNotEnough() {
        var detector = detector()
        #expect(detector.update(reading(router: nil), now: closed + 60) == .none)
        #expect(detector.score == BagDetector.networkWeight)
    }

    /// The accelerometer cannot tell a bag set down from a desk, so carrying is remembered until the lid opens.
    @Test func carryingIsRememberedWhileTheBagRests() {
        var detector = detector()
        detector.update(reading(carriedAt: afterGrace + 10), now: afterGrace + 10)
        #expect(detector.update(reading(carriedAt: nil), now: afterGrace + 4 * 3600) == .careful)
    }

    @Test(arguments: [
        reading(lidClosed: false, carriedAt: afterGrace, router: nil),
        reading(onBattery: false, carriedAt: afterGrace, router: nil),
        reading(externalDisplay: true, carriedAt: afterGrace, router: nil),
    ])
    func anythingPluggedInOrAnOpenLidMeansADesk(_ desk: BagDetector.Reading) {
        var detector = detector()
        #expect(detector.update(desk, now: afterGrace) == .none)
    }

    @Test func openingTheLidForgetsTheCarryingAndTheNetwork() {
        var detector = detector()
        detector.update(reading(carriedAt: afterGrace + 10), now: afterGrace + 10)
        detector.update(reading(lidClosed: false), now: afterGrace + 60)
        // Closed again at the office: its router is the new normal, and the commute there is forgotten.
        let reclosed = afterGrace + 120
        #expect(detector.update(reading(router: "10.0.0.1"), now: reclosed) == .none)
        // And the grace starts over from the new close.
        #expect(detector.update(reading(carriedAt: reclosed + 60, router: "10.0.0.1"), now: reclosed + 60) == .none)
    }

    @Test func closingTheLidWithoutANetworkLeavesTheNetworkOut() {
        var detector = BagDetector()
        detector.update(reading(router: nil), now: closed)
        #expect(detector.update(reading(carriedAt: afterGrace + 10, router: home), now: afterGrace + 10) == .careful)
    }
}

@Suite struct MotionWindowTests {
    /// One second of samples swinging around 1 g by the given amount.
    private func second(_ window: inout MotionWindow, swing: Double) -> Bool {
        for index in 0..<100 { window.add(1 + (index.isMultiple(of: 2) ? swing : -swing)) }
        return window.tick()
    }

    @Test func aMacAtRestIsNotCarried() {
        var window = MotionWindow()
        // 0.0006 g, as measured on a desk.
        let carried = (0..<60).map { _ in second(&window, swing: 0.0006) }
        #expect(!carried.contains(true))
    }

    @Test func walkingWithTheBagIsCarriedAfterFifteenSeconds() {
        var window = MotionWindow()
        let carried = (0..<20).map { _ in second(&window, swing: 0.11) }
        #expect(carried.firstIndex(of: true) == MotionWindow.movingSeconds - 1)
    }

    /// The walk measured had quiet stretches of up to 11 s.
    @Test func shortPausesInTheWalkKeepItCarried() {
        var window = MotionWindow()
        for _ in 0..<20 { _ = second(&window, swing: 0.11) }
        let carried = (0..<11).map { _ in second(&window, swing: 0.0006) }
        #expect(!carried.contains(false))
    }

    @Test func liftingItToAnotherDeskIsNotCarrying() {
        var window = MotionWindow()
        for _ in 0..<10 { _ = second(&window, swing: 0.0006) }
        let carried = (0..<8).map { _ in second(&window, swing: 0.13) } + (0..<20).map { _ in second(&window, swing: 0.0006) }
        #expect(!carried.contains(true))
    }

    /// The running sums must still resolve the small deviation that tells moving from resting.
    @Test func justAboveTheThresholdCountsAsMoving() {
        var window = MotionWindow()
        let carried = (0..<15).map { _ in second(&window, swing: 0.021) }
        #expect(carried.last == true)
    }

    @Test func aSecondWithoutSamplesCountsAsStill() {
        var window = MotionWindow()
        let carried = window.tick()
        #expect(!carried)
    }
}

@Suite struct PauseTests {
    private func pause(_ thermal: ProcessInfo.ThermalState, bag: BagDetector.Level = .none, lidClosed: Bool = false,
                       batteryLow: Bool = false) -> Power.Pause? {
        Power.pause(thermal: thermal, batteryLow: batteryLow, bag: bag, lidClosedUndocked: lidClosed)
    }

    @Test func aBagPutsItToSleepEvenWhenCool() {
        #expect(pause(.nominal, bag: .sleep, lidClosed: true) == .bag)
    }

    /// Heat has the last word, sooner the likelier a bag is.
    @Test func heatPausesSoonerTheLikelierABag() {
        #expect(pause(.serious) == nil)
        #expect(pause(.critical) == .heat)
        #expect(pause(.fair, lidClosed: true) == nil)
        #expect(pause(.serious, lidClosed: true) == .heat)
        #expect(pause(.nominal, bag: .careful, lidClosed: true) == nil)
        #expect(pause(.fair, bag: .careful, lidClosed: true) == .heat)
    }

    @Test func lowBatteryPausesAsBefore() {
        #expect(pause(.nominal, batteryLow: true) == .battery)
        #expect(pause(.nominal) == nil)
    }
}
