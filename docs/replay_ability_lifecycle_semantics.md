# Replay Ability Lifecycle Semantics

This note is a working triage list for ability map visibility. The important
split is between the placed device/object and the activated effect. A wiki
duration often describes the activated effect, not how long the placed object
should remain on the replay map.

For the broader per-agent persistence and velocity checklist, see
`docs/replay_ability_behavior_atlas.md`.

## Immediate Fix

| Ability | Wiki behavior | Decoder/UI decision |
| --- | --- | --- |
| Chamber Rendezvous | The placed anchor remains at its position indefinitely, can be destroyed, and can be recalled. The 1.3 second value is the teleport duration, not the anchor lifetime. | Treat Rendezvous/Teleport utility actors as round-state placed utility and still cap them when the replay exposes `closedAtMs`. |

## High Priority Lifecycle Candidates

These are the abilities most likely to need multi-phase replay evidence instead
of a single fixed display timer.

| Ability | Placed phase | Activated/ended phase to decode | Current risk |
| --- | --- | --- | --- |
| Killjoy Nanoswarm | Grenade sticks, turns invisible, and remains indefinitely until activated, destroyed, death-deactivated, or buy-phase pickup. | Activation/windup/damage cylinder and death/deactivation reveal. | The current `/Nanoswarm|RemoteBees/` rule uses a fixed active-swarm display duration and may under-display the hidden grenade if that actor is the placed grenade lane. |
| Cypher Cyber Cage | Projectile lands, turns invisible, and remains indefinitely until activated or buy-phase pickup. | Activated smoke cylinder lifetime and post-activation removal. | The current `CyberCage` rule uses the 7.25s active cage duration and may under-display the placed cage. |
| Viper Poison Cloud | Gas emitter remains through the round after landing; active smoke toggles on/off with fuel. | Activation, deactivation, fuel depletion, and buy-phase pickup. | The current `PoisonCloud` rule uses an active-fuel heuristic, not emitter lifetime. |
| Viper Toxic Screen | A line of emitters remains indefinitely; the wall repeatedly activates/deactivates with fuel. | Per-emitter placement plus active wall up/down state. | The current `ToxicScreen` rule uses an active-fuel heuristic, not emitter lifetime. |
| Vyse Razorvine | Initial nest turns invisible and remains indefinitely until activated, destroyed, death-deactivated, or buy-phase pickup. | Activated vines duration and destruction/deactivation. | The current `Razorvine` rule uses the 6s active vine duration and may under-display the hidden nest. |
| Vyse Shear | Hidden wall trap remains indefinitely until triggered, destroyed by special map/spike cases, death-deactivated, or buy-phase pickup. | Triggered wall formation and wall expiry. | The current `Shear` rule uses the 6s wall duration and may under-display the trap. |
| Astra Stars | Stars are placed setup objects that can later become Gravity Well, Nova Pulse, Nebula, or be recalled/dissipated. | Star placement/recall plus each transformed effect. | Current rules model the transformed effects, not the base Star setup lifecycle. |

## Already Modeled As Persistent But Still Worth Lifecycle Proof

These rules already use round-state display lifetimes, but they still need
replay-event proof for recalls, destruction, triggered states, or deactivation.

| Ability | Why it still needs proof |
| --- | --- |
| Chamber Trademark | Trap remains indefinitely, but recall/destroy/death/suppression and triggered slow field are separate lifecycle events. |
| Killjoy Alarmbot | Bot remains indefinitely, but recall, proximity deactivation/reactivation, triggered travel, explosion, destruction, death, and suppression are distinct states. |
| Killjoy Turret | Turret remains indefinitely, but recall, proximity deactivation/reactivation, destruction, death, suppression, and firing bursts are distinct states. |
| Cypher Trapwire | Wire remains indefinitely, but trigger, re-arm, destruction, pickup, death, and suppression are distinct states. |
| Cypher Spycam | Camera is a persistent device, but camera possession, dart firing, dart reveal, recall, destruction, death, and suppression are distinct states. |
| Deadlock Sonic Sensor | Sensor remains indefinitely, but trigger windup/concuss, pickup, destruction, death, and suppression are distinct states. |
| Vyse Arc Rose | Rose remains indefinitely, but recall, activation flash, destruction, death, and suppression are distinct states. |

## Source Pages Checked

- https://valorant.fandom.com/wiki/Rendezvous
- https://valorant.fandom.com/wiki/Trademark
- https://valorant.fandom.com/wiki/Nanoswarm
- https://valorant.fandom.com/wiki/Cyber_Cage
- https://valorant.fandom.com/wiki/Poison_Cloud
- https://valorant.fandom.com/wiki/Toxic_Screen
- https://valorant.fandom.com/wiki/Razorvine
- https://valorant.fandom.com/wiki/Shear
- https://valorant.fandom.com/wiki/Stars
- https://valorant.fandom.com/wiki/Alarmbot
- https://valorant.fandom.com/wiki/Turret
- https://valorant.fandom.com/wiki/Trapwire
- https://valorant.fandom.com/wiki/Spycam
- https://valorant.fandom.com/wiki/Sonic_Sensor
- https://valorant.fandom.com/wiki/Arc_Rose
