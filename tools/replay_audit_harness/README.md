# Icarus replay ability audit harness

This is a dependency-free, agent-oriented HTML mirror of the replay map view.
It reads the same replay track JSON, map SVGs, agent icons, ability icons, map
scales, and Valorant-to-Icarus coordinate transforms used by the Flutter app.

## Run

```powershell
node tools/replay_audit_harness/generate_catalog.mjs
node tools/replay_audit_harness/serve.mjs 4173
```

Open `http://127.0.0.1:4173/tools/replay_audit_harness/`, then drop a track
JSON file or provide a repository-relative URL. A track can be loaded directly:

```text
http://127.0.0.1:4173/tools/replay_audit_harness/?track=/tools/valorant_replay_probe/tmp/ad64888d_ascent_full_capture.native.track.json
```

## Agent controls

- `Space`: play or pause
- `J` / `L`: rewind or advance five seconds
- `[` / `]`: previous or next decoded ability event
- `window.replayAudit.getSnapshot()`: return the selected event, derived
  spectator key, active markers, source/map coordinates, coverage diagnostics,
  exact map transform, and exact time as JSON
- `window.replayAudit.setTime(ms)` and `selectEvent(idOrIndex)`: deterministic
  navigation without pixel targeting; invalid IDs throw instead of selecting a
  different event
- `window.replayAudit.getActions()`: logical cast groups with projectile,
  placed-object, and other phases collapsed into one audit action

The event list intentionally renders a bounded window around the selected
event so multi-megabyte native tracks remain responsive. The underlying API
still exposes every decoded event.

The UI warns when decoded ability coverage stops well before the replay ends.
It also flags contradictory identity evidence instead of presenting a suspect
ability label as authoritative.

## Replay-control boundary

The harness prepares exact evidence but does not inject input into VALORANT.
For manual or Computer Use comparison it shows a five-second pre-roll target,
the visible event window, and the derived spectator key. Current VALORANT
anti-cheat/input behavior can reject injected mouse clicks or spectator keys;
that limitation requires a separate reliable replay-control bridge for fully
deterministic frame-by-frame auditing.

## Synchronization

`catalog.generated.js` is generated from the Dart map constants, replay map
transforms, agent definitions, and the current `assets/agents` inventory. Run
the generator whenever maps, agents, or ability assets change.
