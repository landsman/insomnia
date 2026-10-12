import Foundation
import Testing
@testable import Insomnia

/// Replays the use cases from docs/bag-detection.md against BagWeights, the way Insomnia polls: every 30 s
/// from the moment the lid closes. When a weight changes, this says which use case it broke. It checks the
/// weights, not the timing in the app, where the sensor needs 15 s of walking before it counts.
@Suite struct BagScenarioTests {
    /// What the Mac goes through for one minute with the lid closed.
    struct Minute {
        var carried = false
        var onEdge = false
        var router: String? = office
        var hotspot = false
        var thermal = ProcessInfo.ThermalState.nominal
    }

    struct Scenario: CustomTestStringConvertible {
        let name: String
        let minutes: [Minute]
        /// The minutes within which the Mac has to fall asleep, or nil when it must keep working.
        let sleeps: ClosedRange<Double>?
        var testDescription: String { name }
    }

    static let office = "10.0.0.1"
    static let otherBuilding = "10.9.0.1"
    static let phone = "172.20.10.1"

    static func minutes(_ count: Int, _ minute: Minute = Minute()) -> [Minute] { Array(repeating: minute, count: count) }

    static let scenarios: [Scenario] = [
        Scenario(name: "2 min to a meeting room with an access point switch, then an hour there",
                 minutes: minutes(1, Minute(carried: true)) + minutes(1, Minute(carried: true, router: nil)) + minutes(60),
                 sleeps: nil),
        Scenario(name: "2 min to a meeting room on a hotspot, on its edge, then an hour there",
                 minutes: minutes(2, Minute(carried: true, onEdge: true, router: phone, hotspot: true))
                     + minutes(60, Minute(router: phone, hotspot: true)),
                 sleeps: nil),
        Scenario(name: "4 min to a meeting room in another building on another network, warm, then an hour there",
                 minutes: minutes(2, Minute(carried: true, thermal: .fair))
                     + minutes(2, Minute(carried: true, router: otherBuilding, thermal: .fair))
                     + minutes(60, Minute(router: otherBuilding, thermal: .fair)),
                 sleeps: nil),
        Scenario(name: "6 min across the campus in the hand, same office network, then a meeting",
                 minutes: minutes(6, Minute(carried: true)) + minutes(60),
                 sleeps: nil),
        Scenario(name: "Four 2 min carries through a morning, warm on a vertical stand in between",
                 minutes: Array((0..<4).map { _ in
                     minutes(2, Minute(carried: true, onEdge: true, thermal: .fair)) + minutes(30, Minute(onEdge: true, thermal: .fair))
                 }.joined()),
                 sleeps: nil),
        Scenario(name: "Closed on a vertical stand under load, warm, for an hour",
                 minutes: minutes(60, Minute(onEdge: true, thermal: .fair)),
                 sleeps: nil),
        Scenario(name: "Leaving the office on Wi-Fi: walking on its edge, network gone after a minute",
                 minutes: minutes(1, Minute(carried: true, onEdge: true)) + minutes(20, Minute(carried: true, onEdge: true, router: nil)),
                 sleeps: 2...3),
        Scenario(name: "Leaving the office on Wi-Fi with the bag lying flat",
                 minutes: minutes(1, Minute(carried: true)) + minutes(20, Minute(carried: true, router: nil)),
                 sleeps: 3...4),
        Scenario(name: "Leaving the office, Wi-Fi handing over to the phone's hotspot outside",
                 minutes: minutes(1, Minute(carried: true, onEdge: true))
                     + minutes(20, Minute(carried: true, onEdge: true, router: phone, hotspot: true)),
                 sleeps: 2...3),
        Scenario(name: "Leaving on a hotspot: walking on its edge",
                 minutes: minutes(20, Minute(carried: true, onEdge: true, router: phone, hotspot: true)),
                 sleeps: 8...9),
        Scenario(name: "Leaving on a hotspot: walking on its edge and warming up",
                 minutes: minutes(2, Minute(carried: true, onEdge: true, router: phone, hotspot: true))
                     + minutes(20, Minute(carried: true, onEdge: true, router: phone, hotspot: true, thermal: .fair)),
                 sleeps: 5...6),
        Scenario(name: "Walked 4 min out of the office on its edge, then the bag rests in a car",
                 minutes: minutes(1, Minute(carried: true, onEdge: true)) + minutes(3, Minute(carried: true, onEdge: true, router: nil))
                     + minutes(30, Minute(onEdge: true, router: nil)),
                 sleeps: 2...3),
    ]

    /// When the Mac fell asleep, in minutes after the lid closed, or nil.
    static func replay(_ scenario: Scenario, weights: BagWeights = .standard) -> Double? {
        var detector = BagDetector(weights: weights)
        let closed = Date(timeIntervalSince1970: 1_000_000)
        var carriedSeconds = 0
        for step in 0..<(scenario.minutes.count * 2) {
            let minute = scenario.minutes[step / 2]
            if minute.carried && step > 0 { carriedSeconds += 30 }
            let reading = BagDetector.Reading(lidClosed: true, externalDisplay: false, carriedSeconds: carriedSeconds,
                                              onEdge: minute.onEdge, router: minute.router, hotspot: minute.hotspot,
                                              thermal: minute.thermal)
            if detector.update(reading, now: closed + Double(step) * 30) { return Double(step) / 2 }
        }
        return nil
    }

    @Test(arguments: scenarios)
    func comesOutRight(_ scenario: Scenario) {
        let sleptAfter = Self.replay(scenario)
        if let sleeps = scenario.sleeps {
            #expect(sleptAfter.map(sleeps.contains) == true, "slept after \(sleptAfter.map { "\($0) min" } ?? "never")")
        } else {
            #expect(sleptAfter == nil, "slept after \(sleptAfter ?? 0) min")
        }
    }

    /// The scenarios have to be able to fail: with a lower bar the office walks put the Mac to sleep.
    @Test func aLowerSleepScoreBreaksTheOfficeWalks() {
        var eager = BagWeights.standard
        eager.sleepAt = 30
        #expect(Self.scenarios.contains { $0.sleeps == nil && Self.replay($0, weights: eager) != nil })
    }
}
