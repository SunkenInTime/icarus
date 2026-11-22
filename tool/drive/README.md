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

## The cloud store in shadow

`--cloud-store shadow` on Linux, `-CloudStore shadow` on Windows, starts the app with the cloud store in shadow. It uses the same SQLite file as the library store, and either flag works without the other.

The shadow takes results where the repository gets them from the server (`ConvexStrategyRepository.tap`), before the editor upgrades or merges anything: every page the editor watches or reads from the server, and, for every strategy it has seen a page of, a page list it watches itself (`strategy:getPageList`). Each result carries the connection it was handed over on and the account its read was issued under. A read issued while the app was changing its sign-in on the Convex client, or answered after a later change, can't be put to an account, so it is skipped with that reason. The first result with a new connection or account opens a session in the store before it is recorded. Nothing is sent from the store, no edit goes into it, and nothing on screen reads it. Its work runs one job at a time between frames, the way the library mirror does.

One checker lives for the whole run. Every result delivered makes an entry, and so does every failed read. After each result the store is compared with what the server sent, in the order the store was given it, by the store's own rules: the strategy row, the page list and its order, every page's settings, and that page's items and lineup groups, with nothing extra allowed. Each entry ends compared equal, compared different, refused by the store, failed, or skipped for one of six stated reasons: received while offline, read on a connection that has since ended, read under an account that has since changed, read across an account change, the queue answered that its session had ended, or the server refused the read. The driver logs this on `CLOUDSTORE` lines after every step.

At the end of a run the driver stops the shadow's subscriptions and takes its tap off the repository, so nothing more can arrive; waits until its queue is empty, at most 30 s from the last step; and takes the verdict. The run fails unless every entry is equal or skipped, at least one result of each strategy compared equal, and the shadow never stopped. Then the store is closed, opened again from disk, and every strategy is compared whole, on every page, open or not; a strategy missing from the file, anything extra in it, or a run with nothing to compare fails. With the flag off, the driver creates nothing of the shadow.

The driver steps that go with it:

- `{"openStoredCloudStrategy": true}` opens the one cloud strategy the store holds, so a run started on another run's store with `--hive-store` (`scripts/cloud-store-shadow-restart-after.json`) opens the strategy that run left behind.
- `{"signOut": true}` signs out the way a user does, through the confirmation, and `{"signIn": "second"}` signs in to the account given with `--second-account` (`-SecondAccount` on Windows), as `scripts/cloud-store-shadow-switch-account.json` does.
- `{"expectStoredPayloadVersion": id, "version": n}` fails unless the store holds item `id` at payload version `n`, as the server sent it; `scripts/cloud-store-shadow-old-payload.json` sends an item at an older version the way an older build writes it.

`scripts/cloud-store-shadow-offline.json` waits for `cut` and `restored` signals, which `linux-cloud-store-offline.sh <exe dir> <new out dir> <account>` writes: it runs the script inside its own systemd scope, drops that scope's incoming traffic with an nftables rule once the script signals `ready`, and lifts it once the script has edited offline. It needs passwordless `sudo` for `nft` and removes its rule on exit. Linux only.

`getPageList` has to be on the deployment the build talks to.

## The library store in shadow

`--library-store shadow` on Linux, `-LibraryStore shadow` on Windows, starts the app with the library store switched to shadow: as it starts, it copies every local strategy and folder from Hive into a SQLite store beside the Hive boxes (`library_store/library.sqlite`), reads every strategy back out and compares it with Hive. Nothing reads the store yet. `--hive-store DIR` (`-HiveStore`) starts the main instance on a copy of `DIR`, which is never opened itself, so a real library can be checked without touching it.

```sh
dart tool/drive/linux.dart run --script tool/drive/scripts/library-store-shadow.json \
  --library-store shadow --hive-store ~/Code/<scratch>/store
```

Every run logs `FIRSTFRAME <ms> ms store=<off|shadow|mirror>`, the time from the start of `main` to the first frame on screen; `scripts/first-frame.json` does nothing else. The steps:

- `{"libraryStore": "shadow", "seconds": n?, "expect": {...}?}` waits up to n seconds (600 by default) for the copy and the comparison, logs them as `STORE` lines, and fails unless the store opened, the copy finished with nothing left out, every strategy and folder reads back the same as Hive, and neither library box (`strategy_box.hive`, `folder_box.hive`) changed while it ran. Other boxes the app writes on its own in that time are listed, not failed; `test/library_store/shadow_copy_test.dart` hashes every Hive file around the copy alone. `expect` can name counts that must match: `copied`, `unchanged`, `tookHiveVersion`, `removedWithHive`.
- With `"hidden": true`, the step first tells the app it is hidden, as the system does when its window is minimized, so no frame is drawn while it waits, then shows it again. `scripts/library-store-shadow-hidden.json` uses it: the copy and the check must finish without a frame.
- `{"checkLibraryStore": 1}` reads every strategy back again and fails on any difference.

With `--library-store mirror` (`-LibraryStore mirror`) the app does the same copy at start, and after it every save of a local strategy or folder that Hive accepts is followed by the matching store write, through one queue. At the end of every script the driver waits for that queue to drain, checks the store against Hive, logs the `STORE` lines and fails unless it is exact; `{"holdLibraryStore": true}` stops the queue, so a run can end with saves Hive holds and the store does not (`scripts/library-store-mirror-hold.json`), for the next start to bring up to date.

Every run logs `FRAMES whole run`: the frames drawn, the worst one from the start of its build to the end of its raster, how many took over 50 ms, and the longest the main isolate was busy, measured passively from the start of the script to its end.

`test/library_store/drive_runs_test.dart` compares two runs' saved libraries (`ICARUS_COMPARE_RUNS=a:b;c:d`, run ids, generated ids and times set aside) and checks the store a run left against its Hive library without copying first (`ICARUS_CHECK_RUNS=a;b`).

At the end of a run the driver closes the store and logs `STORE closed`.

`--kill-after-seconds S` (Linux only) kills the main instance with SIGKILL S seconds after it starts, as a crash would. Start the next run with `--hive-store <that run's out>/store-main` and `scripts/library-store-shadow.json` to see the copy pick up where it stopped.

## Keeping the two in step

`run.ps1` and `linux.dart` are two launchers for the same driver. The driver decides pass or fail and writes the `SUMMARY` line; the launchers only set it up and read the log. `test/drive_linux_runner_test.dart` fails when the driver reads an `ICARUS_DRIVE_*` variable one launcher doesn't set, when Linux refuses a step the driver no longer has, or when either build stops refusing production. A change to what an instance gets goes into both launchers in the same commit.
