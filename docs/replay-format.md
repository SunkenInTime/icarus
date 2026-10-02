# Decoded replay format

`native/replay` turns a Valorant `.vrf` into one decoded replay: a byte
buffer that Icarus caches on disk as `<sha256-of-vrf>.icrp` and reads in Dart.
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
      "name?": "…",                         // never set yet: the replay carries no display name
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
          "loadoutValue?": 4700,            // never set yet: not replicated per player (13.00)
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
    "<subject>": [[timeMs, health, armor], …] // one row per change; null until the wire states it
  },
  "utility": [
    {
      "id": 4211,                           // actor NetGUID, unique per open
      "classPath": "/Game/Characters/Wraith/Ability_Wraith_4_Smoke…",
      "owner?": "…",                        // subject
      "spawnMs": 61000,
      "endMs?": 76000,                      // actor closed
      "position": [x, y, z],
      "yaw?": 90.0,
      "path?": [[timeMs, x, y, z], …],     // later replicated positions (projectiles, moving walls)
      "points?": [[x, y, z], …]             // shape points (walls, paths drawn in-game)
    }
  ],
  "casts": [
    {
      "timeMs": 60500,
      "subject": "…",
      "slot": 4,                            // the replicated ability slot
      "classPath?": "…",                    // the ability item; absent where the wire does not tie it
      "position?": [x, y, z]
    }
  ],
  "movement": {
    "<subject>": { "offset": 0, "count": 18213 }
  },
  "quality": {
    "transformVerified": true,
    "decodeErrors": 0,
    "warnings": ["…"]
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

Records come from every body in the player's `characterGuids`. A body that
is parked off-map between lives (around x -50000, z -49900) is dropped, not
recorded. `yaw` is 0..360 as replicated; `pitch` is signed, -180..180.

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
