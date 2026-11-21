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

`linux-stall-uploads.sh <exe dir> <new out dir> <label> <account>` runs `scripts/picture-upload-stalled.json` with picture uploads stalled for that run only: inside its own systemd scope, a connection whose TLS hello names `r2.cloudflarestorage.com` goes silent both ways once it has sent 64 KB, so a 197 KB picture never gets an answer while the 5 KB logo, Convex and every other process are untouched. The script signals when to lift it. It needs passwordless `sudo` for `iptables`, removes its rules on exit, and records the run's screen to `<label>.mp4` beside the out dir.

What doesn't run on Linux:

- The `clipboard` step puts a picture on the Windows clipboard through PowerShell. `run` refuses scripts that use it (`paste-on-canvas`, `paste-picture`, `paste-while-busy`).
- MP4 export needs `ffmpeg` on PATH. `run` refuses scripts that export MP4 when it's missing. Transparent MOV uses the app's own encoder.
- Growing the window to 2400x1350 (`spawn-barriers-all-maps`) crashes the Linux app with signal 11. Resizes up to 1600x900 work.
- The app draws system cursors instead of its custom drawing and rotation cursors, because the vendored `custom_mouse_cursor` has no Linux code. Shots don't include the cursor, so they look the same.

## The library store in shadow

`--library-store shadow` on Linux, `-LibraryStore shadow` on Windows, starts the app with the library store switched to shadow: as it starts, it copies every local strategy and folder from Hive into a SQLite store beside the Hive boxes (`library_store/library.sqlite`), reads every strategy back out and compares it with Hive. Nothing reads the store yet. `--hive-store DIR` (`-HiveStore`) starts the main instance on a copy of `DIR`, which is never opened itself, so a real library can be checked without touching it.

```sh
dart tool/drive/linux.dart run --script tool/drive/scripts/library-store-shadow.json \
  --library-store shadow --hive-store ~/Code/<scratch>/store
```

Every run logs `FIRSTFRAME <ms> ms store=<off|shadow>`, the time from the start of `main` to the first frame on screen; `scripts/first-frame.json` does nothing else. The steps:

- `{"libraryStore": "shadow", "seconds": n?, "expect": {...}?}` waits up to n seconds (600 by default) for the copy and the comparison, logs them as `STORE` lines, and fails unless the store opened, the copy finished with nothing left out, every strategy and folder reads back the same as Hive, and no `.hive` file changed while it ran. `expect` can name counts that must match: `copied`, `unchanged`, `tookHiveVersion`, `removedWithHive`.
- `{"checkLibraryStore": 1}` reads every strategy back again and fails on any difference.

At the end of a run the driver closes the store and logs `STORE closed`.

`--kill-after-seconds S` (Linux only) kills the main instance with SIGKILL S seconds after it starts, as a crash would. Start the next run with `--hive-store <that run's out>/store-main` and `scripts/library-store-shadow.json` to see the copy pick up where it stopped.

## Keeping the two in step

`run.ps1` and `linux.dart` are two launchers for the same driver. The driver decides pass or fail and writes the `SUMMARY` line; the launchers only set it up and read the log. `test/drive_linux_runner_test.dart` fails when the driver reads an `ICARUS_DRIVE_*` variable one launcher doesn't set, when Linux refuses a step the driver no longer has, or when either build stops refusing production. A change to what an instance gets goes into both launchers in the same commit.
