# Decoded replay format

`native/replay` turns a Valorant `.vrf` into one decoded replay: a byte
buffer that Icarus caches on disk (one `.icrp` per replay file and decoder
version) and reads in Dart.
It holds Valorant facts only. Nothing in it names an Icarus agent, ability,
page, or widget; `lib/replay/` maps the facts onto Icarus.

The buffer is a cache, rebuilt from the `.vrf` whenever `formatVersion` or
the decoder version changes. It is not part of the library and never goes
into an `.ica` file.

## Container

```
offset  type        field
0       [u8; 4]     magic "ICRP"
4       u32 LE      formatVersion (1)
8       u32 LE      jsonLength
12      [u8]        JSON document, UTF-8, jsonLength bytes
...     [u8]        zero padding to the next multiple of 8
...     [u8]        binary blob (movement records)
```

Offsets inside the JSON that point into the blob are relative to the blob's
first byte.

## Conventions

- Time is milliseconds on the replay timeline (`timeMs`), the clock that
  Event chunks and DemoFrames share. 0 is the start of the recording.
- Positions are Unreal world centimetres `[x, y, z]`, exactly as replicated.
- `yaw` and `pitch` are degrees, Unreal convention: yaw 0 faces +X and grows
  toward +Y; pitch is positive looking up.
- Players are keyed by `subject`, the account UUID from the replay header.
- Teams are Valorant's team ids as replicated: `"Red"` or `"Blue"`.
- Anything the decoder could not establish is absent or `null`, never
  guessed. Optional fields are marked `?`.

## Document

```jsonc
{
  "decoder": { "name": "icarus_replay", "version": "0.1.0+vrfkit.0.2.5", "vrfkit": "0.2.5" },
  "match": {
    "id": "dc078274-2d68-495b-8321-5e58b2a3eeba",
    "mapPath": "/Game/Maps/Juliett/Juliett",
    "build": "++Ares-Core+release-13.00",
    "durationMs": 321499,
    "recordedAt?": "2026-07-08T00:35:45Z",  // the header's FDateTime ticks; no zone on the wire
    "gameMode?": "/Game/GameModes/Bomb/BombGameMode.BombGameMode_C"
  },
  "players": [
    {
      "subject": "978b3946-…",
      "agentId": "1dbf2edd-…",              // valorant-api.com agent UUID; null if the header lacks it
      "team": "Red",                         // null if no combat report names it
      "characterGuids": [1206, 45530]       // every body this player had, in order
    }
  ],
  "rounds": [
    {
      "index": 0,                           // 0-based, in play order
      "startMs": 1203,                      // roundStarted event
      "combatStartMs?": 31203,              // barriers drop (the buy phase ends)
      "endMs": 98000,                       // round decided; the replay's end if it never is
      "attackingTeam": "Red",               // null if no round of its half has a result
      "winningTeam?": "Blue",
      "endReason?": "elimination",          // elimination | detonated | defused | time | surrender
      "plant?": { "timeMs": 80000, "site?": "A", "subject?": "…", "position?": [x, y, z] },
      "defuse?": { "timeMs": 95000, "subject?": "…" },
      "detonateMs?": 125000,
      "economy": [                          // every player, at buy-phase end; empty without one
        {
          "subject": "…",
          "credits": 3900,                  // null if no Money was replicated by then
          "weapon?": "…",                   // primary, else sidearm, equippable class path
          "armor?": 50                      // shield points of the armour worn: 25 or 50
        }
      ]
    }
  ],
  "kills": [
    {
      "timeMs": 52010,
      "victim": "…",
      "killer?": "…",                       // absent for falls, spike and self-inflicted deaths
      "assists": ["…"],
      "damageSource?": "…"                  // weapon or ability class path when known
    }
  ],
  "vitals": {
    "<subject>": [[timeMs, health, armor], …] // see "Vitals"
  },
  "utility": [
    {
      "id": 4211,                           // actor NetGUID, unique per open
      "classPath": "/Game/Characters/Wraith/Ability_Wraith_4_Smoke…",
      "owner?": "…",                        // subject
      "spawnMs": 61000,
      "endMs?": 76000,                      // actor closed
      "position": [x, y, z],
      "yaw?": 90.0,                         // absent only for an actor with no spawn transform
      "path?": [[timeMs, x, y, z], …],     // where it went, about 10 Hz; see "Utility"
      "points?": [[x, y, z], …]             // shape points; see "Utility"
    }
  ],
  "casts": [
    {
      "timeMs": 60500,
      "subject": "…",
      "slot": 4,                            // 3 grenade (C), 4 ability one (Q), 5 ability two (E), 9 ultimate (X)
      "classPath?": "…",                    // the ability item; absent where the wire does not tie it
      "position?": [x, y, z]
    }
  ],
  "movement": {
    "<subject>": { "offset": 0, "count": 18213 }
  },
  "quality": {
    "transformVerified": true,
    "decodeErrors": 0,                      // typed field decodes that failed
    "loss": {                               // see "Quality"
      "malformedPackets": 0,
      "bunchHeaderFailures": 0,
      "lostContentBlocks": 0,
      "rejectedPartials": 0,
      "unfinishedPartials": 0,
      "refusedBunches": 0,
      "unopenedChannelBunches": 0,
      "packageMapExportBunches": 0
    },
    "warnings": ["…"]                       // see "Warnings"
  }
}
```

## Movement records

Each player's movement is `count` records starting at `offset` in the blob,
sorted by time, 24 bytes each, little-endian:

```
i32  timeMs
f32  x
f32  y
f32  z
f32  yaw
f32  pitch
```

Records come from every body in the player's `characterGuids`, wherever it
is. Iso's Kill Contract duels its two players in an arena off the map, around
x ±50000, z -49900, so their records sit there for the duel (6-7 s in our
corpus). `yaw` is 0..360 as replicated; `pitch` is signed, -180..180.

## Vitals

Each player's rows start at the first round's start; nothing is known
before it. Every round opens with a row for every player at health 100, the
reset the game sends each body (the first round's bodies spawn full). After
that there is one row per change: damage and heals set health to the wire's
absolute result, a death leaves it at 0, and a revive (Sage, Clove) is a
reset back to 100. Heals and regenerating shields report every tick, about
125 a second, so a healed player has hundreds of rows.

Armour is the armour item the player wears: bought, it counts its full
points (25 or 50) until it reports a lower value, a survivor carries it into
the next round, and selling it or a round's end after death leaves 0.
Values are rounded to two decimals; both are always numbers.

## Utility

`yaw` is the actor's spawn yaw. A spawn sends its rotation only when it is
not zero, so a spawned actor without one has yaw 0; `yaw` is absent only
for an actor that opened with no spawn transform at all.

`path` is where the actor went while open, from its `ReplicatedMovement`
(projectiles, moving smokes and walls) and, for pawns (Boom Bot, Owl Drone,
Prowler, Wingman, Seekers, Trailblazer, Yoru's decoy and fake teleporter,
Cypher's camera, Killjoy's bots), from the movement records the game sends
for every pawn. Repeats are dropped and points kept at least 100 ms apart,
with the last always kept. It is absent when the actor never left its
`position`.

`points` is a shape, each family's own replicated geometry, in wire order:

| Utility | `points` | Source |
|---|---|---|
| Phoenix's Blaze (`GameObject_Phoenix_Q_FlameWallManager_Production`), Viper's Toxic Screen (`GameObject_Pandemic_E_SmokeScreenManager`, not in our corpus) | the wall, start to end | `MulticastAddSmokeScreenPoint.Translation` |
| Neon's Fast Lane (`GameObject_Sprinter_4_Tunnel`) | the lane, start to end, 125 cm apart | `MulticastAddTunnelPoint.Translation` |
| Vyse's Shear (`GameObject_Nox_Wall`) | the wall's start and end | `MulticastInitializeWall.WallStartLocation`, `WallEndLocation` |
| Vyse's Shear trap (`GameObject_Nox_WallTrap`) | the wall it raises, start and end | `MulticastInitializeTrapAnchors.WallStartPoint`, `WallEndPoint` |
| Deadlock's Barrier Mesh (`GameObject_CableJamRoot`) | each arm's end, one per arm that deployed (a blocked arm has none) | each `GameObject_CableJam_CableDeployer_Precomputed` it owns: `MulticastInitialize.Destination` |
| Cypher's Trapwire (`GameObject_Gumshoe_E_TripWire`) | one point, the far anchor; the actor is the near one | the `GameObject_Gumshoe_E_TripWire_SecondWire` opened with it, same millisecond and `Owner` |

Every other utility has none. The Fast Lane, Shear and Barrier Mesh values
are vectors vrfkit leaves untyped; the decoder reads them as three
little-endian doubles, which put each wall's first point on its actor and
each mesh's `RootLocation` on its root.

## Players

The replay names players by `subject` alone. It carries no display name or
Riot ID: the PlayerState's `ProfileName` is the crosshair profile ("Imported
Crosshair 07-15-2023 14:55:05").

## Casts

`slot` names the ability: 3, 4, 5 and 9 are valorant-api.com's `Grenade`,
`Ability1`, `Ability2` and `Ultimate` of the caster's agent. Every cast of 26
agents across our 7 replays agrees with the item `classPath` where one is
known. `classPath` is the ability item, absent where no charge spend ties a
cast to it (always for ultimates).

## Quality

`transformVerified` is the transform guard's verdict; a decode that fails it
is refused, so a document always says `true`. `decodeErrors` counts field
values vrfkit could not type (its `overlay.decoded_err`).

`loss` is what the replication stream lost before any field was read: the
counters vrfkit's own `validate` judges a replay by. No two count the same
thing, and a payload vrfkit keeps whole when it cannot decode it is not lost.

| Counter | What it counts | vrfkit `NetStats` |
|---|---|---|
| `malformedPackets` | packets abandoned part-read | `malformed_packets` |
| `bunchHeaderFailures` | bunches whose header did not read | `bunch_header_failures` |
| `lostContentBlocks` | actor content blocks whose payload reached no field or RPC | `lost_content_blocks()` |
| `rejectedPartials` | partial-bunch fragments refused during reassembly | `partial_errors` |
| `unfinishedPartials` | partial bunches still incomplete at the end | `unfinished_partials` |
| `refusedBunches` | bunches refused at a channel-state limit | `channel_state_limit_failures` |
| `unopenedChannelBunches` | bunches for a channel with no open actor, dropped | `bunches_on_unopened_channel` |
| `packageMapExportBunches` | bunches whose content after a package-map export is not read | `package_map_exports` |

All are 0 on every replay in our corpus. Each non-zero one is also a
warning.

## Warnings

`quality.warnings` names what the decoder dropped, could not attribute, or
chose between, one line each: losses and decode failures by kind, deaths or
utility it could not attribute, assists it could not separate, rounds the
replay stops inside, and game phases sent twice (where `combatStartMs` takes
the first). A clean replay has none.

## Probe

`icarus_replay_probe` reads the header alone, for a replay list, and returns:

```jsonc
{
  "id": "dc078274-…",
  "mapPath": "/Game/Maps/Juliett/Juliett",
  "build": "++Ares-Core+release-13.00",
  "durationMs": 321499,
  "recordedAt?": "2026-07-08T00:35:45Z",
  "supported": true,                       // a payload transform is registered for the build
  "decoderVersion": "0.1.0+vrfkit.0.2.5",  // same as the document's decoder.version
  "players": [{ "subject": "…", "agentId": "…" }]
}
```

`decoderVersion` changes whenever the decoded output could: it is the crate
version plus the vrfkit tag. A cached `.icrp` decoded under another version
is stale.

## Errors

When decoding fails the library returns an error object instead of a
buffer:

```json
{ "code": "unsupportedBuild", "message": "…", "build": "++Ares-Core+release-13.07" }
```

Codes: `notAReplay`, `unsupportedBuild`, `unsupportedCompression`,
`transformCheckFailed`, `corrupt`, `io`, `cancelled`. `build` is present
whenever the header was read. `transformCheckFailed` means the payloads
decoded into noise: the build's registered transform does not fit the file.
`corrupt` also covers a file that would need more than the decoder's caps
(`native/replay/src/limits.rs`): a file over 512 MB, a schema or record set
several times larger than a real match's.
