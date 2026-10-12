# Sleep When Carried in a Bag

How Insomnia tells leaving with the Mac from carrying it to a meeting room, and why it works the way it does. The setting is off by default.

## The use case

Insomnia exists so a Mac keeps working with the lid closed: people used to walk around the office, and even home, with the lid open so the work would not stop. Two things therefore have to hold at once:

- **A short carry keeps working.** Closing the lid and walking to a meeting room, between floors, to a colleague's desk: the agent or the export goes on.
- **Leaving lets it sleep.** Closing the lid at the end of the day, putting the Mac in a bag and going home: Insomnia steps aside and the Mac sleeps, so it is safe in the bag without anyone having to turn Insomnia off.

A bag is a problem because of heat. A closed Mac in a bag cannot cool, and the battery suffers from heat long before macOS reports it.

## What can be read

| Signal | Source | Notes |
|---|---|---|
| Lid closed | `AppleClamshellState` on `IOPMrootDomain`, with changes delivered by an interest notification | no permission needed |
| External display | `CGGetOnlineDisplayList` and `CGDisplayIsBuiltin` | the built-in display stays in the list with the lid closed, and a sleeping monitor drops out of the *active* list |
| Motion | the accelerometer behind the Sensor Processing Unit on Apple silicon MacBooks: undocumented HID device, page `0xFF00`, usage 3 | readable without root on macOS 27 once its driver is told to report; MacBooks with M1 Pro, M1 Max, or M2 and later have it; Intel Macs, the M1 MacBook Air and Pro, and the MacBook Neo (A18 Pro) do not |
| Network | router from `SCDynamicStore` `State:/Network/Global/IPv4`; `NWPath.isExpensive` for a phone hotspot | many networks share `192.168.0.1` or `192.168.1.1`; IPv6-only networks have no IPv4 router |
| Heat | `ProcessInfo.thermalState` | public, but coarse and late |
| Location | Find My is encrypted and has no API; CoreLocation needs a permission prompt that a menu bar app may never get | not used |

The ambient light sensor sits in the lid and reads dark whenever it is closed, so it says nothing.

## Measurements

A walk on a Mac17,8 with the lid closed, the accelerometer read at 100 Hz, and the deviation of the acceleration magnitude computed per second:

| Phase | Deviation per second, median |
|---|---|
| On the desk | 0.0006 g |
| Turned in the hands | 0.128 g |
| Walking with the bag | 0.110 g (p10 0.015 g, quiet gaps up to 11 s) |
| Bag set down on the floor | 0.0006 g |
| Typing on the open Mac | up to 0.024 g |

From these numbers:

- **A second counts as moving above 0.02 g.**
- **The Mac counts as carried when at least 15 of the last 30 seconds moved.** That window bridges the quiet gaps in a walk and ignores a lift from one desk to another.
- **A bag at rest looks exactly like a desk.** Motion only ever says "is being carried", so carrying is remembered until the lid opens.
- **Motion counts only with the lid closed**, because typing alone crosses the threshold.

At idle the hottest die sensor went from 40 °C to 46 °C after a minute still in the bag, while `thermalState` stayed nominal throughout.

## What did not work

Each rule below failed on a real scenario:

| Rule | Scenario that breaks it |
|---|---|
| Carried, plus the network changed, means a bag | A walk to a meeting room that switches the office network sleeps the Mac within seconds. |
| Carried means a bag | A short carry is the core use case, not a fault. |
| Heat only, no bag detection | Heat arrives late. The Mac sits warm in the bag for a long time before `thermalState` moves. |
| Lost the network means leaving | On a phone hotspot the network travels along and is never lost. |
| Carried for 5 minutes means leaving | Leaving on a hotspot is caught only after 5 minutes, and a long walk across a campus to a meeting is caught too. |

**No single signal decides.** Leaving is a combination of signs, each with a weight.

## Scoring

Signs add up with the lid closed and no external display, whatever the power source, because a power bank in a bag is still a bag. At 70 the Mac sleeps. The weights live in `Sources/BagWeights.swift`, and `Tests/BagScenarioTests.swift` replays the scenarios below against them, polling every 30 s like the app does. A change to a weight that breaks a use case fails the test.

Two rules keep a desk and an office day from scoring:

- **Only the latest trip counts.** A trip is carrying with no stillness longer than 3 minutes, so a lift or a door does not end it. Four 2-minute walks to meeting rooms never add up to the way home. The latest trip is remembered until the next one or the lid opening, because a bag set down reads like a desk.
- **Nothing counts before the Mac was carried for a minute.** A vertical stand, a warm Mac or a network change on a desk scores 0.

| Sign | Weight | Why |
|---|---|---|
| The latest trip, carried for ≥ 1 / 3 / 5 / 8 min | 15 / 30 / 45 / 60 | A carry inside the office is short; the way home is long. |
| Lost the network the lid closed on for ≥ 60 s, or moved onto a phone's hotspot | 40 | Roaming between access points drops the network for seconds; leaving drops it for good. Moving onto a hotspot is how leaving looks for someone who tethers. |
| On another network for ≥ 60 s | 15 | A meeting room in another building, a guest network or another VLAN. |
| Standing on its edge: gravity mostly off the Z axis | 15 | A Mac stands in a backpack and lies flat on a desk. *Not measured yet.* |
| Warming with the lid closed: `thermalState` at `.fair` or above | 20 | It cools in the hand and warms in a bag. *Not measured in a bag yet.* |

The network scores nothing when the lid closed on a hotspot, which travels along, or with no network at all.

How the scenarios come out:

| Scenario | Outcome |
|---|---|
| 2 min to a meeting room with an access point switch, then an hour there | keeps working (15) |
| 2 min to a meeting room on a hotspot, on its edge, then an hour there | keeps working (30) |
| 4 min to a meeting room in another building on another network, warm, then an hour there | keeps working (65) |
| 6 min across the campus in the hand, same office network, then a meeting | keeps working (45) |
| Four 2 min carries through a morning, warm on a vertical stand in between | keeps working (50) |
| Closed on a vertical stand under load, warm, for an hour | keeps working (0) |
| Leaving the office on Wi-Fi: walking on its edge, network gone after a minute | sleeps after 2 min |
| Leaving the office on Wi-Fi with the bag lying flat | sleeps after 3 min |
| Leaving the office, Wi-Fi handing over to the phone's hotspot outside | sleeps after 2 min |
| Leaving on a hotspot: walking on its edge | sleeps after 8 min |
| Leaving on a hotspot: walking on its edge and warming up | sleeps after 5 min |
| Walked 4 min out of the office on its edge, then the bag rests in a car | sleeps after 2 min |

These times check the weights, not the app. In the app the sensor needs about 15 s of walking before it counts, motion only starts once Insomnia notices the lid closed, and a stop-and-go walk counts less, so real times run somewhat later.

**Heat has the last word regardless of the score.** Insomnia pauses at `.critical` anywhere. With this setting on, it also pauses at `.serious` with the lid closed and no external display, for the bags the score misses, and a pause for heat or a bag with the lid closed lasts until the lid opens, so a wake after cooling down never holds the Mac awake in the bag again. With the setting off, Insomnia behaves as it always has. After such a sleep the menu says why for 15 minutes ("Slept at 17:42 when you left with it").

**Where it cannot help.** A Mac without the accelerometer could never score, since every sign needs a trip first, so the setting is not offered there at all: Settings shows a line saying which MacBooks have the sensor in place of the toggle, and a value carried over from another Mac stays off, heat pause included. On a Mac with the sensor that line never appears. The gate is the accelerometer's driver in the IORegistry, not a list of models, so a future MacBook with the sensor works and one without it drops out by itself. A flat bag carried on a hotspot reaches only 60 without warming up, and a car ride that does not shake the Mac adds no carrying; heat is the backstop for both.

## Open questions

- **Orientation in a bag versus in the hand.** The measured walk logged only the magnitude, not the axes.
- **`isExpensive` on a real iPhone hotspot.** It is documented, but not checked on this Mac.
- **Vibration in a car, a train or a plane** against the 0.02 g threshold.
- **How fast a Mac under load heats up in a bag**, and when it reaches `.fair` and `.serious`.
- **The router address is a weak network identity.** A Wi-Fi BSSID would be stronger, but reading it needs the location permission.
