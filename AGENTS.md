Do not try to edit *.g.dart files, edit the source files and then run code generation

After code edits, assume a running Windows Flutter app should be hot reloaded unless the change clearly requires a restart or no app is running. Do this as part of finishing the change, not as an optional follow-up.

Windows Flutter dev runs should be started with the `frunwin` PowerShell helper from the repo root. It runs `fvm flutter --print-dtd run -d windows --disable-service-auth-codes`, streams Flutter output, and writes run metadata to `C:\Users\shawn\.codex\flutter-runs\<project>.json` plus `latest.json`.

Before attempting reload automation, use the global `flutter-run-registry` skill and read the registry file whose `cwd` matches this repo. Use its `dtdUri` with the Dart MCP `dtd` connect command, then call Dart MCP `hot_reload` with the returned app URI. If Dart MCP is unavailable, fall back to the registry `vmServiceUri` for inspection or the Flutter runner terminal. If reload is skipped or fails, say exactly why.
