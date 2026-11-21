# Driver runs

A driver build is the desktop app with `lib/dev/drive/drive.dart` compiled in. It plays a JSON script from `scripts/` the way a user would and writes a log that ends in `SUMMARY ... CLEAN` or `SUMMARY ... PROBLEMS`. The steps are listed at the top of `lib/dev/drive/drive.dart`.

A run passes only when every instance finished its script with `SUMMARY ... CLEAN` and quit before the timeout. The Linux runner also needs the app's exit code to be 0. `run.ps1` doesn't check it, because Windows builds don't report a trustworthy one. Flutter errors, items drawn away from their saved positions, failed steps and cloud work that never settles all fail it.

## Windows

`build.ps1` and `run.ps1`; each one's header says how. Final checks happen here: Icarus ships to Windows, macOS and the web.

## Linux

Linux is for fast iteration on a box like t3os, where many agents can each verify on their own screen. It is not a platform Icarus ships to, so finish on Windows.

```sh
dart tool/drive/linux.dart build
dart tool/drive/linux.dart run --script tool/drive/scripts/right-click-local.json
dart tool/drive/linux.dart run --script tool/drive/scripts/shape-opacity-cloud.json \
  --companion tool/drive/scripts/shape-opacity-cloud-teammate.json \
  --account <email> --companion-account <other email>
```

`build` puts the build in `build/drive-linux` and talks to the dev deployment, or to a preview with `--convex <url>`. Production is refused. `run` starts its own Xvfb screen, so it needs no desktop and leaves every other screen alone. Each instance keeps its store, session, app data and log under `--out`, `drive-<run>` beside the build by default. Shots land there too, and so does the app's own error log (`home-<instance>/data/com.example.icarus/icarus_debug.log`), which holds startup errors that happen before the driver can log. `run` exits 0 when clean, 1 otherwise, and 2 when the script can't run here. `--help` lists every option.

Passwords come from `~/.agents/secrets/icarus/test-accounts.md`, or over `ssh windows` when that file is not on this machine. They go only into the app's environment.

What doesn't run on Linux:

- The `clipboard` step puts a picture on the Windows clipboard through PowerShell. `run` refuses scripts that use it (`paste-on-canvas`, `paste-picture`, `paste-while-busy`).
- MP4 export needs `ffmpeg` on PATH. `run` refuses scripts that export MP4 when it's missing. Transparent MOV uses the app's own encoder.
- Growing the window to 2400x1350 (`spawn-barriers-all-maps`) crashes the Linux app with signal 11. Resizes up to 1600x900 work.
- The app draws system cursors instead of its custom drawing and rotation cursors, because the vendored `custom_mouse_cursor` has no Linux code. Shots don't include the cursor, so they look the same.

## Scripts that need the network cut

`lost-answer-edit` and `delete-undo-lost-answer` lose the answer to a change on purpose. Each signals `ready`, then waits for `armed`: cut the run's incoming traffic and write the run id (from `<out>/run-id`) to `<out>/signals/armed`. Its requests still reach the server, so the change lands and the answer never arrives. `delete-undo-lost-answer` then signals `undone`; restore the traffic and write `restored`. On Linux, start the run in its own scope (`systemd-run --user --scope --unit <name> -- dart tool/drive/linux.dart run ...`) and drop only that scope's incoming packets with an nftables rule, `socket cgroupv2 level 5 "user.slice/user-1000.slice/user@1000.service/app.slice/<name>.scope" drop` in an input chain, so no other run on the box goes offline.

## Keeping the two in step

`run.ps1` and `linux.dart` are two launchers for the same driver. The driver decides pass or fail and writes the `SUMMARY` line; the launchers only set it up and read the log. `test/drive_linux_runner_test.dart` fails when the driver reads an `ICARUS_DRIVE_*` variable one launcher doesn't set, when Linux refuses a step the driver no longer has, or when either build stops refusing production. A change to what an instance gets goes into both launchers in the same commit.
