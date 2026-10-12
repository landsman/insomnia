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
| Motion | the accelerometer behind the Sensor Processing Unit on Apple silicon MacBooks: undocumented HID device, page `0xFF00`, usage 3 | readable without root on macOS 27 once its driver is told to report; Intel Macs and the 2020 M1 MacBook Pro do not have it |
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

## Proposed scoring

The score only counts with the lid closed and no external display, whatever the power source, because a power bank in a bag is still a bag. At 70 the Mac sleeps.

| Sign | Weight | Why |
|---|---|---|
| Carried after the lid closed, for ≥ 1 / 3 / 5 / 8 min | 15 / 30 / 45 / 60 | A carry inside the office is short; the way home is long. |
| Left the network: lost for ≥ 60 s, or on a new network for ≥ 60 s | 30 | Roaming between access points drops the network for seconds; leaving drops it for good. Scores 0 on a hotspot (`isExpensive`), which travels along. |
| Standing on its edge: gravity off the Z axis | 15 | A Mac stands in a backpack and lies flat on a desk. *Not measured yet.* |
| Warming with the lid closed: `thermalState` at `.fair` or above | 20 | It cools in the hand and warms in a bag. |

How the scenarios come out:

| Scenario | Score | Outcome |
|---|---|---|
| 2 min to a meeting room, access point switch | 15 | keeps working |
| 2 min to a meeting room on a hotspot, on its edge | 30 | keeps working |
| Leaving the office on Wi-Fi: 3 min walk, network lost, on its edge | 75 | sleeps after about 3 min |
| Leaving on a hotspot: 8 min walk, on its edge | 75 | sleeps after about 8 min |
| Leaving on a hotspot: 5 min walk, on its edge, warming | 80 | sleeps after about 5 min |

**Heat has the last word regardless of the score.** Insomnia pauses at `.critical` anywhere, and at `.serious` with the lid closed and no external display, which applies even with this setting off. A pause for heat or for a bag with the lid closed lasts until the lid opens, so a wake after cooling down never holds the Mac awake in the bag again.

## Open questions

- **Orientation in a bag versus in the hand.** The measured walk logged only the magnitude, not the axes.
- **`isExpensive` on a real iPhone hotspot.** It is documented, but not checked on this Mac.
- **Vibration in a car, a train or a plane** against the 0.02 g threshold.
- **How fast a Mac under load heats up in a bag**, and when it reaches `.fair` and `.serious`.
- **The router address is a weak network identity.** A Wi-Fi BSSID would be stronger, but reading it needs the location permission.
