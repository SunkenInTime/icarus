# Replay Ability Behavior Atlas

This atlas is a wiki-informed checklist for replay decoder work. It is not a
replacement for replay proof. Use it to know what evidence to look for, then
only promote behavior when the replay exposes a cast row, utility actor,
movement sample, actor close, trigger, recall, destroy, death, or round-state
transition that proves the lifecycle.

The key distinction:

- `abilityCasts[]` is the canonical "player used an ability" lane.
- `utilityActors[]` is map-visible phase evidence, such as a projectile,
  placed object, area patch, deployable pawn, or component movement track.
- Wiki durations often describe the active effect, not the placed object's
  lifetime. This is the Chamber Rendezvous and Killjoy Nanoswarm class of bug.

## Velocity Rules

| Velocity model | Meaning | Decoder guidance |
| --- | --- | --- |
| none | No utility actor velocity should be expected. | Map-click placements, self buffs, hitscan weapons, beams, static traps, and deployed devices should not move because a timer says so. End them by actor close, recall, destroy, trigger, death, suppression, round end, or proven state change. |
| projectile | A thrown/fired travel phase should have a projectile or missile path. | Spawn velocity is useful for the travel phase only. Do not invent the impact point or final lifetime from velocity alone. Look for landed actors, patches, close bunches, or paired phase links. |
| movement-samples | A controlled or autonomous object moves after spawn. | Prefer `samples[]` or ComponentDataStream movement tracks over one actor-open velocity. This is the Boom Bot, Owl Drone, Trailblazer, Seeker, Prowler, Wingman, Thrash family. |
| player-motion | The ability moves or changes the player, not a utility actor. | Track this through player state/movement, ability casts, and teleport/dash events. Do not render a fake utility projectile. |
| beam-wave | The effect travels as a beam, wave, cone, pulse, or expanding area. | Model origin, direction, width/range, and timed propagation when proven. A utility velocity vector is usually the wrong abstraction. |
| hybrid | The ability has multiple phases with different behavior. | Split projectile flight, placed object, active effect, pickup/recall, and death/round-state endpoints instead of assigning one display timer. |

## Lifecycle Triage

These abilities should be treated as persistent/setup or multi-phase before any
fixed-duration display rule is trusted:

- Astra Stars and all Star transformations.
- Chamber Trademark and Rendezvous.
- Cypher Trapwire, Cyber Cage, and Spycam.
- Deadlock Sonic Sensor.
- Gekko globules after Mosh Pit, Wingman, Dizzy, or Thrash expire.
- Killjoy Nanoswarm, Alarmbot, Turret, and Lockdown.
- Phoenix Run It Back return marker.
- Veto Crosscut, Chokehold, and Interceptor.
- Viper Poison Cloud, Toxic Screen, and Viper's Pit.
- Vyse Razorvine, Shear, and Arc Rose.
- Yoru Fakeout inactive echo and Gatecrash tether.

## Ability Atlas

| Agent | Ability | Wiki behavior hint | Persistence expectation | Velocity expectation | Replay evidence to seek |
| --- | --- | --- | --- | --- | --- |
| Jett | Cloudburst | Projectile smoke, optionally held as a guided missile. | Short active smoke after travel. | projectile, with guided path when held | Projectile/missile flight, final smoke actor or patch, smoke close. |
| Jett | Updraft | Self-targeted vertical dash. | Player state only. | player-motion | Player movement/state change, no utility actor. |
| Jett | Tailwind | Self-targeted dash state and dash use. | Player state only. | player-motion | Activation window, dash movement, cooldown/recharge. |
| Jett | Blade Storm | Hitscan weapon equip. | Weapon/player state only. | none | Equip/fire rows, hit or kill effects if exposed. |
| Raze | Boom Bot | Grounded autonomous deployable. | Moving pawn until expiry, detonation, or destruction. | movement-samples | Component movement track, target acquisition, explosion, close/destroy. |
| Raze | Blast Pack | Projectile that sticks, then detonates or times out. | Landed pack persists briefly until reactivated or expiry. | hybrid: projectile then none | Flight, landed/stuck actor, detonation, close. |
| Raze | Paint Shells | Projectile cluster grenade with submunitions. | Flight plus timed explosions. | projectile | Main grenade flight, cluster submunition actors, detonation patches. |
| Raze | Showstopper | Rocket launcher equip, rocket fired as missile. | Weapon equip plus rocket flight. | projectile for fired rocket | Equip/fire event, missile actor, impact/explosion. |
| Phoenix | Blaze | Missile wall that leaves a path. | Timed wall after path creation. | beam-wave or missile path | Wall path samples/segments, active wall close. |
| Phoenix | Hot Hands | Projectile fireball that detonates on terrain. | Timed molotov patch. | projectile | Flight, landed fire patch, patch close. |
| Phoenix | Curveball | Missile flash on fixed curved path. | Flash moment only. | projectile | Missile path and detonation/flash event. |
| Phoenix | Run It Back | Self-targeted revive/return marker. | Return marker persists until expiry, death return, or cancel. | none for marker, player-motion for return | Cast marker, player death/return state, marker close. |
| Astra | Gravity Well | Targeted Star transformation. | Active effect only after a Star is transformed. | none | Star identity, activation, pull effect, close. |
| Astra | Nova Pulse | Targeted Star transformation with windup then concuss. | Active effect only after a Star is transformed. | none | Star identity, activation/windup, concuss event, close. |
| Astra | Nebula/Dissipate | Targeted Star smoke or Star recall/dissipate. | Star persists until transformed/recalled; smoke is timed. | none | Star placement, transform, recall/fake smoke, active smoke close. |
| Astra | Cosmic Divide | Placement wall. | Timed global wall. | none | Two endpoints or line placement, active wall duration/close. |
| Astra | Stars | Setup placements in Astral Form. | Persistent setup objects until transformed, recalled, round end, or death rules. | none | Star placement, stable identity, transform/recall/end. |
| Breach | Aftershock | Terrain placement charge. | Short delayed blasts, not a persistent placed trap. | beam-wave | Placement origin/direction, blast pulses, close. |
| Breach | Flashpoint | Terrain placement flash. | Short delayed flash, not a persistent placed trap. | beam-wave | Placement origin/direction, flash detonation. |
| Breach | Fault Line | Grounded AoE line. | Charged wave/cone effect. | beam-wave | Charge length, origin/direction/range, detonation rows. |
| Breach | Rolling Thunder | Grounded AoE cascading quake. | Timed traveling wave. | beam-wave | Origin/direction, sequential blasts, end time. |
| Viper | Snake Bite | Projectile canister that creates molotov. | Timed acid patch after impact. | projectile | Flight, landed patch, patch close. |
| Viper | Poison Cloud | Projectile emitter that sticks and toggles smoke. | Emitter persists through round until pickup/round end; smoke toggles by fuel. | hybrid: projectile then none | Flight, landed emitter, active/inactive smoke state, pickup/round end. |
| Viper | Toxic Screen | Projectile lays emitters, then wall toggles. | Emitters persist; wall toggles by fuel. | hybrid: projectile line then none | Emitter line placement, active/inactive wall state, round end. |
| Viper | Viper's Pit | Placement cloud around Viper. | Persistent ult cloud while owner conditions are met. | none | Cast origin, active cloud boundary, owner death/leave/end state. |
| Yoru | Fakeout | Instant moving echo or inactive placed echo. | Inactive echo persists until activated/expired/destroyed; active echo moves. | hybrid: movement-samples when active | Setup placement, activation, decoy movement, destruction/expiry. |
| Yoru | Blindside | Bouncing projectile flash. | Flash moment after bounce/detonation. | projectile | Projectile bounces, detonation, flash event. |
| Yoru | Gatecrash | Mobile tether or stationary placed tether. | Tether persists until teleport/fakeout/expiry/destroyed. | hybrid: movement-samples then none | Mobile tether path, stationary state, teleport/fakeout, close. |
| Yoru | Dimensional Drift | Self-targeted intangibility. | Player state only. | none | Cast, player state duration, end. |
| Sova | Owl Drone | Possessed controlled deployable with hitscan dart. | Moving drone until cancelled/expired/destroyed. | movement-samples | Drone movement samples, possession state, dart fire/reveal, close. |
| Sova | Shock Bolt | Charged projectile arrow. | Impact/damage moment. | projectile | Arrow flight/bounces, impact. |
| Sova | Recon Bolt | Charged projectile arrow that becomes reveal object. | Landed bolt persists for scan duration or until destroyed. | hybrid: projectile then none | Flight/bounces, landed dart, scan pulses, destroy/close. |
| Sova | Hunter's Fury | Beam weapon equip and beam shots. | Weapon/player state plus beam pulses. | beam-wave | Equip/fire rows, beam origin/direction, hit events. |
| Skye | Regrowth | Heal aura from Skye. | Channel/player state only. | none | Cast/channel state, affected allies, end. |
| Skye | Trailblazer | Possessed controlled deployable. | Moving pawn until leap, expiry, cancel, or destruction. | movement-samples | Movement samples, leap/explosion/concuss, close. |
| Skye | Guiding Light | Guided missile hawk that flashes. | Moving hawk until flash/expiry/destroyed. | projectile or movement-samples | Hawk path, flash trigger, close/destroy. |
| Skye | Seekers | Autonomous grounded objects. | Moving seeker pawns until hit/expired/destroyed. | movement-samples | Per-seeker movement, target link, hit/close. |
| KAY/O | FRAG/ment | Projectile grenade, underhand variant. | Timed damage pulses after landing. | projectile | Flight, landed grenade/patch, pulse/end. |
| KAY/O | FLASH/drive | Projectile flash, underhand variant. | Flash moment after fuse. | projectile | Flight, bounce/fuse, flash event. |
| KAY/O | ZERO/point | Projectile knife with health that suppresses. | Landed knife persists briefly for pulse or until destroyed. | hybrid: projectile then none | Flight, landed knife, suppress pulse, destroy/close. |
| KAY/O | NULL/cmd | Self buff with emitted pulses and revive state. | Player state plus repeated area pulses. | beam-wave for pulses, no utility velocity | Cast, pulse timings, downed/revive state, end. |
| Killjoy | Nanoswarm | Projectile grenade that sticks, hides, then activates as molotov. | Hidden grenade persists indefinitely until activate, destroy, pickup, death deactivation, or round end. | hybrid: projectile then none | Flight, hidden landed grenade, activation, active swarm close, destroy/death. |
| Killjoy | Alarmbot | Placed autonomous deployable trap. | Persists until trigger, recall, destroy, death/suppression, proximity state, or round end. | none while placed, movement-samples if triggered travel exists | Placement, active/disabled state, trigger travel/explosion, recall/destroy/death. |
| Killjoy | Turret | Placed autonomous deployable. | Persists until recall, destroy, death/suppression, range state, or round end. | none while placed | Placement, active/disabled state, firing bursts, recall/destroy/death. |
| Killjoy | Lockdown | Placed detain device with health. | Device persists through windup until detonation/destroy/death/round end. | none | Placement, windup, destroy/detonate, detain effect. |
| Brimstone | Stim Beacon | Tossed projectile that creates buff field. | Timed field after landing. | projectile | Flight, field patch, close. |
| Brimstone | Incendiary | Bouncing projectile grenade. | Timed molotov patch after detonation. | projectile | Flight/bounces, landed fire patch, close. |
| Brimstone | Sky Smoke | Tactical map placement smoke. | Timed smoke at clicked location. | none | Map-click placement, smoke actor/patch, close. |
| Brimstone | Orbital Strike | Tactical map placement strike. | Timed strike area. | none | Map-click placement, strike pulses, close. |
| Cypher | Trapwire | Placed autonomous deployable wire. | Persists until trigger, pickup, destroy, death/suppression, or round end. | none | Placement endpoints, trigger/rearm, destroy/pickup/death. |
| Cypher | Cyber Cage | Tossed projectile that becomes invisible device, then active smoke. | Hidden cage persists indefinitely until activated/picked up/round end. | hybrid: projectile then none | Flight, landed cage, activation, smoke close, pickup. |
| Cypher | Spycam | Placed camera, possessed view, missile dart. | Camera persists until recall, destroy, death/suppression, or round end. | none for camera, projectile for dart if modeled | Camera placement, possession, dart fire/reveal, recall/destroy/death. |
| Cypher | Neural Theft | Targeted corpse intel. | Cast/effect only. | none | Corpse target, reveal pulses, end. |
| Chamber | Trademark | Placed autonomous deployable trap. | Persists until trigger, recall, destroy, death/suppression, or round end. | none | Placement, trigger, slow field, recall/destroy/death. |
| Chamber | Headhunter | Hitscan weapon equip. | Weapon/player state only. | none | Equip/fire/ammo state. |
| Chamber | Rendezvous | Placed teleport anchor with health. | Anchor remains indefinitely until recalled, destroyed, or round end; teleport duration is not anchor lifetime. | none for anchor, player-motion for teleport | Anchor placement, teleport activation, recall/destroy/close. |
| Chamber | Tour De Force | Hitscan sniper equip; kill creates slow field. | Weapon/player state plus conditional slow field. | none for weapon | Equip/fire/kill, slow field actor/close. |
| Fade | Prowler | Grounded autonomous deployable, steerable by hold fire. | Moving pawn until hit, expiry, or destroyed. | movement-samples | Movement samples, target lock/hit, close/destroy. |
| Fade | Seize | Projectile knot that activates on terrain. | Timed tether/field after landing. | projectile | Flight, landed field, close. |
| Fade | Haunt | Projectile watcher with health and scan duration. | Landed watcher persists briefly or until destroyed. | hybrid: projectile then none | Flight, landed eye, reveal pulses, destroy/close. |
| Fade | Nightfall | Grounded AoE wave. | Traveling wave/effect. | beam-wave | Origin/direction/range, hit events, end. |
| Neon | Fast Lane | Missile that creates parallel walls. | Timed walls after travel. | beam-wave or missile path | Origin/path, wall segments, close. |
| Neon | Relay Bolt | Projectile bolt that bounces and creates concuss zones. | Timed concuss zones after impacts. | projectile | Flight/bounces, impact zones, close. |
| Neon | High Gear | Self speed state and slide. | Player state only. | player-motion | State activation, movement/slide, end. |
| Neon | Overdrive | Hitscan beam weapon with High Gear state. | Weapon/player state only. | none | Equip/fire, hit events, end. |
| Omen | Shrouded Step | Placement teleport destination. | Player teleport channel/state only. | player-motion | Destination placement, channel, teleport completion/cancel. |
| Omen | Paranoia | Missile near-sight orb through terrain. | Traveling effect only. | projectile or beam-wave | Origin/direction/path, hit events. |
| Omen | Dark Cover | Smoke missile from phased map targeting. | Timed smoke at final location. | hybrid: missile then none | Target placement, moving orb if exposed, smoke close. |
| Omen | From the Shadows | Map placement teleport with cancel/fake states. | Player teleport state only. | player-motion | Destination, channel, arrival/cancel/death. |
| Reyna | Leer | Missile eye with health. | Eye persists briefly or until destroyed. | hybrid: projectile then none | Eye spawn/path, active near-sight, destroy/close. |
| Reyna | Devour | Self-targeted heal from Soul Orb. | Player/orb tether state only. | none | Orb availability, tether, heal/end. |
| Reyna | Dismiss | Self-targeted intangibility from Soul Orb. | Player state only. | player-motion | Orb consume, intangible state, end. |
| Reyna | Empress | Self empowerment. | Player state only. | none | Cast, state duration/reset/end. |
| Sage | Barrier Orb | Placement wall segments with health. | Wall persists until duration, destroy, or round state. | none | Segment placement, health/fortify, destroy/close. |
| Sage | Slow Orb | Projectile slow orb. | Timed slow field after impact. | projectile | Flight, field patch, close. |
| Sage | Healing Orb | Targeted or self heal. | Player/target state only. | none | Target, heal ticks/end. |
| Sage | Resurrection | Targeted corpse revive. | Player/corpse state only. | none | Corpse target, revive windup, alive state. |
| Clove | Pick-me-up | Self empowerment/heal after eligible death. | Player state only. | none | Eligibility, cast, heal/state end. |
| Clove | Meddle | Projectile fragment that sticks and explodes. | Timed vulnerable/decay effect after impact. | projectile | Flight, impact, effect area/end. |
| Clove | Ruse | Map placement smoke. | Timed smoke at clicked locations. | none | Map-click placements, smoke actors, close. |
| Clove | Not Dead Yet | Self revive/intangibility after death. | Player death/revive state only. | player-motion after revive | Death eligibility, revive cast, survival/expiry. |
| Iso | Contingency | Grounded moving wall object. | Moving wall until expiry. | movement-samples or beam-wave | Wall movement samples/path, close. |
| Iso | Undercut | Missile through terrain. | Traveling debuff effect only. | projectile | Origin/direction/path, hit events. |
| Iso | Double Tap | Self shield/empowerment. | Player state and orb/shield state. | none | Shield state, orb spawn/collect if exposed, end. |
| Iso | Kill Contract | Grounded AoE/arena effect. | Cast area and duel state. | beam-wave | Column/area target, captured players, arena start/end. |
| Deadlock | Barrier Mesh | Projectile disc that creates barrier mesh. | Barrier nodes persist until duration/destroy. | hybrid: projectile then none | Disc flight, central/small orbs, health/destroy/close. |
| Deadlock | Sonic Sensor | Placed autonomous deployable. | Persists until trigger, pickup, destroy, death/suppression, or round end. | none | Placement, trigger/windup/concuss, pickup/destroy/death. |
| Deadlock | GravNet | Projectile grenade, underhand variant. | Timed field/debuff after landing. | projectile | Flight, field patch, close. |
| Deadlock | Annihilation | Beam that can bounce; cocoon pulls target. | Beam shot plus target/cocoon state if hit. | beam-wave, player-motion for pulled target | Beam path/bounce, hit, cocoon movement/state, close. |
| Gekko | Mosh Pit | Projectile creature that becomes area explosion and globule. | Timed detonation; globule may persist for reclaim. | projectile, then none for globule | Flight, detonation patch, globule spawn/pickup/expire. |
| Gekko | Wingman | Grounded autonomous deployable, spike plant/defuse targeting. | Moving pawn until task, hit, expiry, or destroyed; globule after expiry. | movement-samples | Movement, task state, hit/destroy, globule spawn/pickup/expire. |
| Gekko | Dizzy | Projectile/windup deployable that fires blasts, then globule. | Moving/hovering actor until expiry/destroyed; globule after expiry. | hybrid: projectile/movement-samples | Path, blast fire rows, destroy/close, globule lifecycle. |
| Gekko | Thrash | Possessed controlled deployable, then globule if recoverable. | Moving pawn until lunge/detonation/expiry/destroyed. | movement-samples | Possession movement, lunge/detain, close, globule lifecycle. |
| Harbor | Storm Surge | Projectile that activates on horizontal terrain. | Timed zone after impact. | projectile | Flight, impact zone, close. |
| Harbor | High Tide | Missile wall path. | Timed wall after path creation. | beam-wave or missile path | Wall path, segments, close. |
| Harbor | Cove | Missile smoke shield with health. | Timed smoke/shield after landing or until shield destroyed. | hybrid: missile then none | Missile path, landed cove, shield health/destroy, smoke close. |
| Harbor | Reckoning | Grounded moving wave/area. | Traveling area with strike pulses. | beam-wave or movement-samples | Wave path/area, geyser strikes, end. |
| Vyse | Razorvine | Projectile nest that hides, then activates as slow vines. | Hidden nest persists indefinitely until activate, destroy, pickup/death/round end. | hybrid: projectile then none | Flight, hidden nest, activation, active vine close, destroy/death. |
| Vyse | Shear | Placed hidden wall trap. | Trap persists indefinitely until triggered, destroyed by rules, death, pickup, or round end. | none | Placement, trigger, active wall close, destroy/death. |
| Vyse | Arc Rose | Placed flash device. | Rose persists until activated, recall, destroy, death/suppression, or round end. | none | Placement, activation/flash, recall/destroy/death. |
| Vyse | Steel Garden | Emission over a large area. | Timed area effect. | beam-wave | Cast origin/area, thorns/effect rows, end. |
| Tejo | Stealth Drone | Possessed controlled deployable. | Moving drone until cancelled/expired/destroyed. | movement-samples | Drone movement, possession state, fire/mark actions, close. |
| Tejo | Special Delivery | Sticky projectile, with alt-fire bounce. | Timed concuss after impact. | projectile | Flight/bounce, impact, detonation, close. |
| Tejo | Guided Salvo | Tactical map placement missiles. | Targeted strike areas after launch. | hybrid: map placement plus projectile/strike | Map clicks, missile/strike actors, impact patches, close. |
| Tejo | Armageddon | Tactical map placement strike line. | Timed strike sequence. | beam-wave or none | Map placement line/area, sequential explosions, close. |
| Waylay | Saturate | Projectile cluster that sticks and activates. | Timed hinder field after impact. | projectile | Flight, impact/cluster, field close. |
| Waylay | Lightspeed | Self dash chain. | Player state/movement only. | player-motion | Dash start/end samples, reactivation/alt-fire path. |
| Waylay | Refract | Self cast creates return beacon. | Beacon persists until return/expiry; player state changes during recall. | none for beacon, player-motion for return | Beacon placement, return activation, close/expiry. |
| Waylay | Convergent Paths | Grounded AoE beam plus self buff. | Timed expanding/projected area and player buff. | beam-wave | Origin/direction/area, hit events, buff state/end. |
| Veto | Crosscut | Placed vortex teleport device. | Vortex persists until teleport/recall/destroy/round end. | none for vortex, player-motion for teleport | Placement, teleport activation, recall/destroy/close. |
| Veto | Chokehold | Projectile trap that sticks, then tethers/cripples. | Landed trap persists until trigger, destroy, pickup/death, or round end. | hybrid: projectile then none | Flight, hidden/placed trap, trigger/tether, destroy/close. |
| Veto | Interceptor | Missile-cast utility defense device with health. | Placed device persists until charges/expiry/destroy/round end. | hybrid: missile then none | Cast path, placed interceptor, intercepted utility events, destroy/close. |
| Veto | Evolution | Self empowerment/heal/immunity. | Player state only. | none | Cast, mutation state, heal/immunity/end. |
| Miks | M-pulse Concuss | Local split of wiki M-pulse concuss output; projectile device. | Landed device pulses/concusses, then ends or is destroyed. | projectile then none | Flight, landed device, pulse, close/destroy. |
| Miks | M-pulse Healing | Local split of wiki M-pulse healing output; projectile device. | Landed device pulses/heals, then ends or is destroyed. | projectile then none | Flight, landed device, pulse, close/destroy. |
| Miks | Harmonize | Targeted or self buff. | Player/ally state only. | none | Target selection, buff state, end/reset. |
| Miks | Waveform | Map placement smoke. | Timed smoke at clicked locations. | none | Map-click placement, smoke actor/patch, close. |
| Miks | Bassquake | Grounded AoE cone/wave. | Timed projected area effect. | beam-wave | Origin/direction/cone, hit/push/slow events, end. |

## Decoder Implications

- Do not remove persistent setup objects on the active-effect duration. Chamber
  Rendezvous, Killjoy Nanoswarm, Cypher Cyber Cage, Viper Poison Cloud, Vyse
  Razorvine, and similar abilities need separate placed and activated phases.
- Do not use actor-open velocity as a lifecycle endpoint. It can suggest a
  projectile travel phase, but the final map position and display lifetime need
  a landed actor, patch actor, movement samples, close bunch, or phase link.
- Do not expect utility velocity for map-click smokes, self buffs, hitscan
  weapons, beams, placed devices, or player teleports/dashes.
- Controlled/autonomous deployables should graduate to `samples[]` when their
  movement lane is proven. A single spawn velocity is not enough for objects
  that steer, chase, bounce, or are possessed.
- Round-state caps are acceptable display safeguards, but docs and emitted
  `durationSource` should make them explicit so they are not confused with
  wiki active-effect durations.

## Source Pages Checked

Shared wiki references:

- https://valorant.fandom.com/wiki/Abilities
- https://valorant.fandom.com/wiki/Deployment_types

Ability pages:

- https://valorant.fandom.com/wiki/Aftershock
- https://valorant.fandom.com/wiki/Alarmbot
- https://valorant.fandom.com/wiki/Annihilation
- https://valorant.fandom.com/wiki/Arc_Rose
- https://valorant.fandom.com/wiki/Armageddon
- https://valorant.fandom.com/wiki/Barrier_Mesh
- https://valorant.fandom.com/wiki/Barrier_Orb
- https://valorant.fandom.com/wiki/Bassquake
- https://valorant.fandom.com/wiki/Blade_Storm
- https://valorant.fandom.com/wiki/Blast_Pack
- https://valorant.fandom.com/wiki/Blaze
- https://valorant.fandom.com/wiki/Blindside
- https://valorant.fandom.com/wiki/Boom_Bot
- https://valorant.fandom.com/wiki/Chokehold
- https://valorant.fandom.com/wiki/Cloudburst
- https://valorant.fandom.com/wiki/Contingency
- https://valorant.fandom.com/wiki/Convergent_Paths
- https://valorant.fandom.com/wiki/Cosmic_Divide
- https://valorant.fandom.com/wiki/Cove
- https://valorant.fandom.com/wiki/Crosscut
- https://valorant.fandom.com/wiki/Curveball
- https://valorant.fandom.com/wiki/Cyber_Cage
- https://valorant.fandom.com/wiki/Dark_Cover
- https://valorant.fandom.com/wiki/Devour
- https://valorant.fandom.com/wiki/Dimensional_Drift
- https://valorant.fandom.com/wiki/Dismiss
- https://valorant.fandom.com/wiki/Dizzy
- https://valorant.fandom.com/wiki/Double_Tap
- https://valorant.fandom.com/wiki/Empress
- https://valorant.fandom.com/wiki/Evolution
- https://valorant.fandom.com/wiki/Fakeout
- https://valorant.fandom.com/wiki/Fast_Lane
- https://valorant.fandom.com/wiki/Fault_Line
- https://valorant.fandom.com/wiki/FLASH-drive
- https://valorant.fandom.com/wiki/Flashpoint
- https://valorant.fandom.com/wiki/FRAG-ment
- https://valorant.fandom.com/wiki/From_the_Shadows
- https://valorant.fandom.com/wiki/Gatecrash
- https://valorant.fandom.com/wiki/GravNet
- https://valorant.fandom.com/wiki/Gravity_Well
- https://valorant.fandom.com/wiki/Guided_Salvo
- https://valorant.fandom.com/wiki/Guiding_Light
- https://valorant.fandom.com/wiki/Harmonize
- https://valorant.fandom.com/wiki/Haunt
- https://valorant.fandom.com/wiki/Headhunter
- https://valorant.fandom.com/wiki/Healing_Orb
- https://valorant.fandom.com/wiki/High_Gear
- https://valorant.fandom.com/wiki/High_Tide
- https://valorant.fandom.com/wiki/Hot_Hands
- https://valorant.fandom.com/wiki/Hunter%27s_Fury
- https://valorant.fandom.com/wiki/Incendiary
- https://valorant.fandom.com/wiki/Interceptor
- https://valorant.fandom.com/wiki/Kill_Contract
- https://valorant.fandom.com/wiki/Leer
- https://valorant.fandom.com/wiki/Lightspeed
- https://valorant.fandom.com/wiki/Lockdown
- https://valorant.fandom.com/wiki/M-pulse
- https://valorant.fandom.com/wiki/Meddle
- https://valorant.fandom.com/wiki/Mosh_Pit
- https://valorant.fandom.com/wiki/Nanoswarm
- https://valorant.fandom.com/wiki/Nebula_/_Dissipate
- https://valorant.fandom.com/wiki/Neural_Theft
- https://valorant.fandom.com/wiki/Nightfall
- https://valorant.fandom.com/wiki/Not_Dead_Yet
- https://valorant.fandom.com/wiki/Nova_Pulse
- https://valorant.fandom.com/wiki/NULL-cmd
- https://valorant.fandom.com/wiki/Orbital_Strike
- https://valorant.fandom.com/wiki/Overdrive
- https://valorant.fandom.com/wiki/Owl_Drone
- https://valorant.fandom.com/wiki/Paint_Shells
- https://valorant.fandom.com/wiki/Paranoia
- https://valorant.fandom.com/wiki/Pick-me-up
- https://valorant.fandom.com/wiki/Poison_Cloud
- https://valorant.fandom.com/wiki/Prowler
- https://valorant.fandom.com/wiki/Razorvine
- https://valorant.fandom.com/wiki/Reckoning
- https://valorant.fandom.com/wiki/Recon_Bolt
- https://valorant.fandom.com/wiki/Refract
- https://valorant.fandom.com/wiki/Regrowth
- https://valorant.fandom.com/wiki/Relay_Bolt
- https://valorant.fandom.com/wiki/Rendezvous
- https://valorant.fandom.com/wiki/Resurrection
- https://valorant.fandom.com/wiki/Rolling_Thunder
- https://valorant.fandom.com/wiki/Ruse
- https://valorant.fandom.com/wiki/Run_it_Back
- https://valorant.fandom.com/wiki/Saturate
- https://valorant.fandom.com/wiki/Seekers
- https://valorant.fandom.com/wiki/Seize
- https://valorant.fandom.com/wiki/Shear
- https://valorant.fandom.com/wiki/Shock_Bolt
- https://valorant.fandom.com/wiki/Showstopper
- https://valorant.fandom.com/wiki/Shrouded_Step
- https://valorant.fandom.com/wiki/Sky_Smoke
- https://valorant.fandom.com/wiki/Slow_Orb
- https://valorant.fandom.com/wiki/Snake_Bite
- https://valorant.fandom.com/wiki/Sonic_Sensor
- https://valorant.fandom.com/wiki/Special_Delivery
- https://valorant.fandom.com/wiki/Spycam
- https://valorant.fandom.com/wiki/Stars
- https://valorant.fandom.com/wiki/Steel_Garden
- https://valorant.fandom.com/wiki/Stealth_Drone
- https://valorant.fandom.com/wiki/Stim_Beacon
- https://valorant.fandom.com/wiki/Storm_Surge
- https://valorant.fandom.com/wiki/Tailwind
- https://valorant.fandom.com/wiki/Tour_De_Force
- https://valorant.fandom.com/wiki/Toxic_Screen
- https://valorant.fandom.com/wiki/Trademark
- https://valorant.fandom.com/wiki/Trailblazer
- https://valorant.fandom.com/wiki/Trapwire
- https://valorant.fandom.com/wiki/Thrash
- https://valorant.fandom.com/wiki/Turret
- https://valorant.fandom.com/wiki/Undercut
- https://valorant.fandom.com/wiki/Updraft
- https://valorant.fandom.com/wiki/Viper%27s_Pit
- https://valorant.fandom.com/wiki/Waveform
- https://valorant.fandom.com/wiki/Wingman
- https://valorant.fandom.com/wiki/ZERO-point
