import Foundation
import Testing
@testable import Insomnia

private let closed = Date(timeIntervalSince1970: 1_000_000)
private let office = "10.0.0.1"
private let weights = BagWeights.standard

/// A Mac closed on the office network, lying still and cool, unless a test says otherwise.
private func reading(lidClosed: Bool = true, externalDisplay: Bool = false, carriedSeconds: Int = 0, onEdge: Bool = false,
                     router: String? = office, hotspot: Bool = false,
                     thermal: ProcessInfo.ThermalState = .nominal) -> BagDetector.Reading {
    .init(lidClosed: lidClosed, externalDisplay: externalDisplay, carriedSeconds: carriedSeconds, onEdge: onEdge,
          router: router, hotspot: hotspot, thermal: thermal)
}

/// A detector that saw the lid close at `closed` and then a minute of carrying.
private func carriedAMinute() -> BagDetector {
    var detector = BagDetector()
    detector.update(reading(), now: closed)
    detector.update(reading(carriedSeconds: 60), now: closed + 60)
    return detector
}

@Suite struct BagDetectorTests {
    @Test func carryingScoresByHowLongTheTripLasts() {
        var detector = BagDetector()
        detector.update(reading(), now: closed)
        detector.update(reading(carriedSeconds: 59), now: closed + 60)
        #expect(detector.score == 0)
        detector.update(reading(carriedSeconds: 60), now: closed + 90)
        #expect(detector.score == 15)
        detector.update(reading(carriedSeconds: 8 * 60), now: closed + 600)
        #expect(detector.score == 60)
    }

    /// The sensor counts from whenever it started, which may be long before this lid close.
    @Test func theFirstReadingIsOnlyABaseline() {
        var detector = BagDetector()
        detector.update(reading(carriedSeconds: 5000), now: closed)
        detector.update(reading(carriedSeconds: 5000), now: closed + 600)
        #expect(detector.score == 0)
    }

    /// Short carries through a day never add up to the way home.
    @Test func aLongStillnessStartsANewTrip() {
        var detector = carriedAMinute()
        detector.update(reading(carriedSeconds: 120), now: closed + 120)
        detector.update(reading(carriedSeconds: 120), now: closed + 3600)
        detector.update(reading(carriedSeconds: 180), now: closed + 3660)
        #expect(detector.score == 15)
    }

    /// A lift or a door stops the walk for less than the gap.
    @Test func aShortStopKeepsTheTripGoing() {
        var detector = carriedAMinute()
        detector.update(reading(carriedSeconds: 120), now: closed + 120)
        detector.update(reading(carriedSeconds: 180), now: closed + 300)
        #expect(detector.score == 30)
    }

    /// A bag set down reads like a desk, so the trip counts until the lid opens.
    @Test func theTripIsRememberedWhileTheBagRests() {
        var detector = carriedAMinute()
        detector.update(reading(carriedSeconds: 200), now: closed + 240)
        detector.update(reading(carriedSeconds: 200), now: closed + 4 * 3600)
        #expect(detector.score == 30)
    }

    /// A vertical stand and a warm Mac on a desk never score on their own.
    @Test func nothingCountsBeforeTheMacWasCarried() {
        var detector = BagDetector()
        detector.update(reading(), now: closed)
        detector.update(reading(onEdge: true, router: nil, thermal: .fair), now: closed + 3600)
        #expect(detector.score == 0)
    }

    @Test func aNetworkGoneForAMinuteCountsAndASecondsLongDropDoesNot() {
        var detector = carriedAMinute()
        detector.update(reading(carriedSeconds: 60, router: nil), now: closed + 90)
        detector.update(reading(carriedSeconds: 60, router: nil), now: closed + 120)
        #expect(detector.score == 15)
        detector.update(reading(carriedSeconds: 60, router: nil), now: closed + 150)
        #expect(detector.score == 15 + weights.lostNetwork)
        detector.update(reading(carriedSeconds: 60), now: closed + 180)
        #expect(detector.score == 15)
    }

    @Test func anotherNetworkCountsLessThanNone() {
        var detector = carriedAMinute()
        detector.update(reading(carriedSeconds: 60, router: "10.9.0.1"), now: closed + 90)
        detector.update(reading(carriedSeconds: 60, router: "10.9.0.1"), now: closed + 150)
        #expect(detector.score == 15 + weights.otherNetwork)
    }

    /// Off the office Wi-Fi onto a phone's hotspot is how leaving looks for someone who tethers.
    @Test func movingOntoAHotspotCountsAsLosingTheNetwork() {
        var detector = carriedAMinute()
        detector.update(reading(carriedSeconds: 60, router: "172.20.10.1", hotspot: true), now: closed + 90)
        detector.update(reading(carriedSeconds: 60, router: "172.20.10.1", hotspot: true), now: closed + 150)
        #expect(detector.score == 15 + weights.lostNetwork)
    }

    /// A hotspot travels along, so closing on one leaves the network out entirely.
    @Test func closedOnAHotspotTheNetworkNeverCounts() {
        var detector = BagDetector()
        detector.update(reading(router: "172.20.10.1", hotspot: true), now: closed)
        detector.update(reading(carriedSeconds: 60, router: nil), now: closed + 60)
        detector.update(reading(carriedSeconds: 60, router: nil), now: closed + 300)
        #expect(detector.score == 15)
    }

    @Test func closedWithoutANetworkTheNetworkNeverCounts() {
        var detector = BagDetector()
        detector.update(reading(router: nil), now: closed)
        detector.update(reading(carriedSeconds: 60), now: closed + 60)
        detector.update(reading(carriedSeconds: 60), now: closed + 300)
        #expect(detector.score == 15)
    }

    @Test func edgeAndWarmthAddTheirWeightsOnceCarried() {
        var detector = carriedAMinute()
        detector.update(reading(carriedSeconds: 60, onEdge: true, thermal: .fair), now: closed + 90)
        #expect(detector.score == 15 + weights.onEdge + weights.warm)
    }

    @Test(arguments: [reading(lidClosed: false), reading(externalDisplay: true)])
    func anOpenLidOrADisplayForgetsEverything(_ desk: BagDetector.Reading) {
        var detector = carriedAMinute()
        detector.update(reading(carriedSeconds: 600, onEdge: true, router: nil, thermal: .fair), now: closed + 600)
        #expect(detector.isLeaving)
        detector.update(desk, now: closed + 630)
        #expect(detector.score == 0)
        // Closed again elsewhere: its network is the new normal, and the walk there is forgotten.
        detector.update(reading(carriedSeconds: 600, router: "10.9.0.1"), now: closed + 660)
        detector.update(reading(carriedSeconds: 630, router: "10.9.0.1"), now: closed + 900)
        #expect(detector.score == 0)
    }

    @Test func otherWeightsCanBeTried() {
        var light = BagWeights.standard
        light.onEdge = 70
        var detector = BagDetector(weights: light)
        detector.update(reading(), now: closed)
        detector.update(reading(carriedSeconds: 60), now: closed + 60)
        let leaving = detector.update(reading(carriedSeconds: 60, onEdge: true), now: closed + 90)
        #expect(leaving)
    }
}

@Suite struct MotionWindowTests {
    /// One second of samples swinging around 1 g by the given amount, lying flat unless on an edge.
    private func second(_ window: inout MotionWindow, swing: Double, onEdge: Bool = false) -> Bool {
        for index in 0..<100 {
            let g = 1 + (index.isMultiple(of: 2) ? swing : -swing)
            onEdge ? window.add(x: g, y: 0, z: 0.1) : window.add(x: 0, y: 0, z: -g)
        }
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

    @Test func standingOnAnEdgeIsTold() {
        var window = MotionWindow()
        _ = second(&window, swing: 0.0006)
        #expect(!window.onEdge)
        _ = second(&window, swing: 0.0006, onEdge: true)
        #expect(window.onEdge)
    }

    @Test func aSecondWithoutSamplesCountsAsStill() {
        var window = MotionWindow()
        let carried = window.tick()
        #expect(!carried)
    }
}

@Suite struct PauseTests {
    private func pause(_ thermal: ProcessInfo.ThermalState, leaving: Bool = false, lidClosed: Bool = false,
                       batteryLow: Bool = false) -> Power.Pause? {
        Power.pause(thermal: thermal, batteryLow: batteryLow, leaving: leaving, lidClosedUndocked: lidClosed)
    }

    @Test func leavingPutsItToSleepEvenWhenCool() {
        #expect(pause(.nominal, leaving: true, lidClosed: true) == .bag)
    }

    /// Heat has the last word: critical anywhere, serious with the lid closed away from a dock.
    @Test func heatPausesSoonerWithTheLidClosed() {
        #expect(pause(.serious) == nil)
        #expect(pause(.critical) == .heat)
        #expect(pause(.fair, lidClosed: true) == nil)
        #expect(pause(.serious, lidClosed: true) == .heat)
    }

    @Test func lowBatteryPausesAsBefore() {
        #expect(pause(.nominal, batteryLow: true) == .battery)
        #expect(pause(.nominal) == nil)
    }

    /// Cooled down with the lid still closed, it stays asleep in the bag.
    @Test func aHeatOrBagPauseHoldsUntilTheLidOpens() {
        #expect(Power.latch(.heat, latched: nil, lidClosedUndocked: true, watchesForBag: true) == .heat)
        #expect(Power.latch(nil, latched: .heat, lidClosedUndocked: true, watchesForBag: true) == .heat)
        #expect(Power.latch(nil, latched: .bag, lidClosedUndocked: true, watchesForBag: true) == .bag)
        #expect(Power.latch(nil, latched: .heat, lidClosedUndocked: false, watchesForBag: true) == nil)
    }

    @Test func aBatteryPauseIsNeverHeld() {
        #expect(Power.latch(.battery, latched: nil, lidClosedUndocked: true, watchesForBag: true) == nil)
    }

    /// With the bag safeguard off, Insomnia behaves as it always has.
    @Test func nothingIsHeldWithTheBagSafeguardOff() {
        #expect(Power.latch(.heat, latched: nil, lidClosedUndocked: true, watchesForBag: false) == nil)
        #expect(Power.latch(nil, latched: .heat, lidClosedUndocked: true, watchesForBag: false) == nil)
    }
}
