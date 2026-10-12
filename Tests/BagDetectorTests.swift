import Foundation
import Testing
@testable import Insomnia

private let start = Date(timeIntervalSince1970: 1_000_000)
private let home = "192.168.0.1"

/// A Mac closed on battery at home, at rest and cool, unless a test says otherwise.
private func reading(lidClosed: Bool = true, onBattery: Bool = true, externalDisplay: Bool = false,
                     carriedAt: Date? = nil, router: String? = home,
                     thermal: ProcessInfo.ThermalState = .nominal) -> BagDetector.Reading {
    .init(lidClosed: lidClosed, onBattery: onBattery, externalDisplay: externalDisplay,
          carriedAt: carriedAt, router: router, thermal: thermal)
}

@Suite struct BagDetectorTests {
    @Test func closedAtRestOnADeskIsNoBag() {
        var detector = BagDetector()
        #expect(detector.update(reading(), now: start) == .none)
        #expect(detector.score == 0)
    }

    @Test func carryingAloneMakesItCareful() {
        var detector = BagDetector()
        detector.update(reading(), now: start)
        #expect(detector.update(reading(carriedAt: start + 40), now: start + 40) == .careful)
    }

    @Test func carryingOffToAnotherNetworkPutsItToSleep() {
        var detector = BagDetector()
        detector.update(reading(), now: start)
        detector.update(reading(carriedAt: start + 40), now: start + 40)
        #expect(detector.update(reading(router: "10.0.0.1"), now: start + 300) == .sleep)
    }

    @Test func losingTheNetworkCountsAsLeaving() {
        var detector = BagDetector()
        detector.update(reading(carriedAt: start), now: start)
        #expect(detector.update(reading(router: nil), now: start + 60) == .sleep)
    }

    /// Warm and carried stays careful, which already pauses at serious heat rather than critical.
    @Test func carriedAndWarmStaysCareful() {
        var detector = BagDetector()
        detector.update(reading(carriedAt: start), now: start)
        #expect(detector.update(reading(thermal: .fair), now: start + 120) == .careful)
        #expect(detector.score == BagDetector.carriedWeight + BagDetector.heatWeight)
    }

    /// A router outage or a warm room without any carrying stays below careful.
    @Test func networkOrHeatWithoutCarryingIsNotEnough() {
        var detector = BagDetector()
        detector.update(reading(), now: start)
        #expect(detector.update(reading(router: nil), now: start + 60) == .none)
        #expect(detector.update(reading(router: nil, thermal: .fair), now: start + 90) == .careful)
    }

    /// The accelerometer cannot tell a bag set down from a desk, so carrying is remembered.
    @Test func carryingIsRememberedWhileTheBagRests() {
        var detector = BagDetector()
        detector.update(reading(carriedAt: start), now: start)
        #expect(detector.update(reading(carriedAt: nil), now: start + 29 * 60) == .careful)
        #expect(detector.update(reading(carriedAt: nil), now: start + 31 * 60) == .none)
    }

    @Test(arguments: [
        reading(lidClosed: false, carriedAt: start, router: nil, thermal: .serious),
        reading(onBattery: false, carriedAt: start, router: nil, thermal: .serious),
        reading(externalDisplay: true, carriedAt: start, router: nil, thermal: .serious),
    ])
    func anythingPluggedInOrAnOpenLidMeansADesk(_ desk: BagDetector.Reading) {
        var detector = BagDetector()
        #expect(detector.update(desk, now: start) == .none)
    }

    @Test func openingTheLidForgetsTheCarryingAndTheNetwork() {
        var detector = BagDetector()
        detector.update(reading(carriedAt: start), now: start)
        detector.update(reading(lidClosed: false), now: start + 60)
        // Closed again at the office: its router is the new normal, and the walk there is forgotten.
        #expect(detector.update(reading(router: "10.0.0.1"), now: start + 120) == .none)
    }

    @Test func closingTheLidWithoutANetworkLeavesTheNetworkOut() {
        var detector = BagDetector()
        detector.update(reading(router: nil), now: start)
        #expect(detector.update(reading(router: home), now: start + 60) == .none)
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

    @Test func aSecondWithoutSamplesCountsAsStill() {
        var window = MotionWindow()
        let carried = window.tick()
        #expect(!carried)
    }
}

@Suite struct PauseTests {
    @Test func aBagPutsItToSleepEvenWhenCool() {
        #expect(Power.pause(thermal: .nominal, batteryLow: false, bag: .sleep) == .bag)
    }

    @Test func maybeInABagPausesOnSeriousHeat() {
        #expect(Power.pause(thermal: .serious, batteryLow: false, bag: .careful) == .heat)
        #expect(Power.pause(thermal: .serious, batteryLow: false, bag: .none) == nil)
    }

    @Test func criticalHeatAndLowBatteryPauseAsBefore() {
        #expect(Power.pause(thermal: .critical, batteryLow: false, bag: .none) == .heat)
        #expect(Power.pause(thermal: .nominal, batteryLow: true, bag: .none) == .battery)
        #expect(Power.pause(thermal: .nominal, batteryLow: false, bag: .none) == nil)
    }
}
