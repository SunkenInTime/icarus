# Valorant ability lifecycle schema notes

Retrieval date: 2026-07-10  
Patch reflected: v12.10  
Coverage: 29 current agents, 116 C/Q/E/X ability records

## Scope and field semantics

This schema targets the current PC roster and follows the placed-versus-activated lifecycle distinction in `docs/replay_ability_lifecycle_semantics.md`. Ability and agent names are aligned with `ability_identity_index.json`; developer codenames come only from `VALORANT_AGENT_ARCHETYPE_TOKENS` in `extract_track.mjs`.

`usesPerRound` records the base charge count or maximum simultaneous uses shown by the current wiki, not a guaranteed hard per-round total. Kill recharges, timed recharges, shared charge pools, Gekko reclaim, and similar exceptions are described in each record's notes.

`spawnsActor` includes persistent deployables, walls, zones, smokes, controlled creatures/drones, beacons, and other independently observable world sources. It excludes ordinary transient projectiles, weapon equips, and self-only buffs.

A null `maxLifetimeSeconds` means either:

- the ability does not spawn an actor, so lifetime is not applicable; or
- the actor persists until activation, destruction, recall, round end, or another interaction without a fixed timer.

A null `hp` normally means the actor is indestructible or HP is not applicable. A null suppression interaction means the current wiki did not document the behavior clearly enough to classify it.

## Patch provenance

The newest explicit wiki patch page found during retrieval was [Patch Notes 12.10](https://valorant.fandom.com/wiki/Patch_Notes/12.10), dated 2026-05-27. Direct current agent and ability pages were preferred over aggregate tables when values conflicted. Some aggregate pages lagged direct pages, including costs and recently reworked abilities.

## Known uncertainties and wiki gaps

- **Miks — M-pulse:** The wiki lists 50 HP, three pulses, the first pulse after 1 second, and a rate of 0.5 pulses/second, but not one total lifetime. The schema's 5-second lifetime is derived. Suppression behavior is undocumented.
- **Veto:** Crosscut's displayed 1.6 seconds appears to describe the teleport sequence, not how long its placed vortex remains. Crosscut and Chokehold therefore use null pre-trigger lifetimes. Suppression behavior is undocumented for all four Veto abilities.
- **Vyse — Shear:** The suppression interaction list documents Razorvine and Arc Rose but omits Shear, so the field is null rather than inferred.
- **Omen — From the Shadows:** The destination Shade is documented as destroyable, but the wiki does not list an HP scalar.
- **Harbor — Storm Surge:** Formation and resulting slow timing are listed, but a single total whirlpool lifetime is not clear.
- **Deadlock — GravNet:** Lifetime depends on a caught player removing the net or the round ending; there is no single fixed scalar.
- **Astra:** Stars are a shared setup resource rather than a fifth slot. C/Q/E records reference the shared 150-credit Star cost and persistent placed-Star phase.
- **Gekko:** Lifetimes combine active creature duration with the subsequent 20-second reclaimable Globule window. Wingman's spike task can extend its active phase.
- **Reyna — Empress:** Current Empress has no fixed timer and lasts until death or round end. Older pages and localized snippets that still say 30 seconds are stale.
- **Recall versus pickup:** Cypher Trapwire and Spycam expose recall/retrieval behavior and are marked recallable and pickupable. Cyber Cage is pickupable only during Buy Phase and is not remotely recallable during live play.
- **Direct-page precedence:** Where the Abilities/Credits aggregate pages disagreed with a current direct page, the direct agent or ability page won. Examples included M-pulse, Fast Lane, and Barrier Orb costs.

## Requested spot checks

- **Killjoy Turret:** Current wiki value is **100 HP**, not 125. The 125 value is historical and was reduced to 100 in patch v6.03. Source: https://valorant.fandom.com/wiki/Turret
- **Sage Barrier Orb:** 40-second wall lifetime; 400 initial HP and 600 fortified HP per segment; the wall decays near expiry. Source: https://valorant.fandom.com/wiki/Sage
- **Cypher Cyber Cage:** Placed phase is indefinite until activation/round end; active cage lasts 7.25 seconds. Source: https://valorant.fandom.com/wiki/Cyber_Cage
- **Sova Owl Drone:** 7-second lifetime and 100 HP. The older 125 HP value was reduced in v4.08. Source: https://valorant.fandom.com/wiki/Owl_Drone
- **Viper Fuel:** Poison Cloud or Toxic Screen alone can consume the 100 Fuel pool for 12 seconds; running both gives about 8.5 seconds. Emitters persist for the round and suppression drops active effects without destroying them. Source: https://valorant.fandom.com/wiki/Viper

## Null-field summary

- `agentCodename`: no nulls; every current agent was present in the repository mapping.
- `maxLifetimeSeconds`: intentionally null for non-actors and indefinite/interaction-bound actors; genuine timing gaps are called out above.
- `hp`: null for non-destroyable/non-actor entries and for Omen's undocumented Shade HP.
- `suppressionInteraction`: null for M-pulse, Veto C/Q/E/X, and Vyse Shear.
- Numeric values were left null when the wiki did not support a defensible value; derived values are labeled in record notes.
