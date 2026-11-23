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

The shadow hears of every page the repository hands to the editor, the slices' fallback to the saved whole page included, after the editor has it (`ConvexStrategyRepository.tap`): as the server sent it, before the editor upgrades or merges anything, with the connection the app was on when the page was handed over. Nothing the shadow does can delay, change or stop what the editor gets. For the strategy the editor has open, it also watches the page list (`strategy:getPageList`), naming the account it serves (`accountSubject`), so the server refuses the watch rather than answer it as anyone else; settings are taken only from the page list, by the store's rule. The first result on a newer connection opens a session in the store before it is recorded. Nothing is sent from the store, no edit goes into it, and nothing on screen reads it. Its work runs one job at a time between frames, the way the library mirror does.

A shadow serves one account: the one signed in at the first sign-in it sees. Any later change of sign-in ends it for good. What it recorded before the change is still judged; nothing after it is recorded, and nothing new starts in that run. A page read through a share link is not taken.

The shadow proves the store records faithfully what it is given. It does not prove it is given everything the editor was given: that claim belongs to the step where the editor reads from the store, where it holds by construction. After each result it records, the store is compared with what the recorded results say it should hold, in order, by the store's own rules: the strategy row, the page list and its order, every page's row and settings, and the items and lineup groups of the page the result was for, with nothing extra allowed. Each recorded result ends compared equal, compared different, refused by the store or unreadable; a result received offline, on a connection that has since ended, or that the queue answered was from an ended session, is skipped. The driver logs this on `CLOUDSTORE` lines after every step.

At the last step the driver stops the shadow taking results and closes its page list watch, then waits for the shadow's queue to empty and the watch to close, at most 30 s from the last step. The run fails if any recorded result compared different, was refused or unreadable, if work was left, or if the shadow stopped. Then the store is closed, opened again from disk and compared whole against the same expectation: every strategy's row, page list and settings, and the contents of every page it recorded; a strategy missing from the file, anything extra in it, or nothing to compare fails. A counts line, printed and never judged, says how many pages were handed to the editor, how many the shadow recorded, and how many were skipped or not taken and why. With the flag off, nothing of the shadow is created.

The driver steps that go with it:

- `{"openStoredCloudStrategy": true}` opens the one cloud strategy the store holds, so a run started on another run's store with `--hive-store` (`scripts/cloud-store-shadow-restart-after.json`) opens the strategy that run left behind.
- `{"expectPageListRefusedNaming": subject}` reads the open strategy's page list naming account `subject` and fails unless the server refuses it with `ACCOUNT_MISMATCH`; run it signed in as another account to see a read that names someone else refused.
- `{"expectBatchRefusedNaming": subject, "readsAccountMismatch": true}` sends the open strategy an empty `applyBatch` naming account `subject` and fails unless the server refuses it: with `ACCOUNT_MISMATCH` when `readsAccountMismatch` is true, with `FORBIDDEN`, as shipped builds get it, when false. `scripts/account-mismatch.json` runs both and the page list refusal, signed in as anyone but the account it names (jules@'s).
- `{"expectStoredPayloadVersion": id, "version": n}` fails unless the store holds item `id` at payload version `n`, as the server sent it; `scripts/cloud-store-shadow-old-payload.json` sends an item at an older version the way an older build writes it.

`scripts/cloud-store-shadow-offline.json` waits for `cut` and `restored` signals, which `linux-cloud-store-offline.sh <exe dir> <new out dir> <account>` writes: it runs the script inside its own systemd scope, drops that scope's incoming traffic with an nftables rule once the script signals `ready`, and lifts it once the script has edited offline. It needs passwordless `sudo` for `nft`, removes its rule on exit, and stops its run if it exits early. Linux only.

`getPageList` has to be on the deployment the build talks to.

### Sending from the store

`--cloud-store send` (`-CloudStore send`) runs the shadow and, beside it, a sender for the store's queue (`lib/library_store/cloud_sender.dart`, over `sender_store.dart`). The sender works out each strategy's next step from facts every time anything changes: what the store holds for that strategy, the connection, the account signed in and the sign-in count, the run's holds, and what it has outstanding for that strategy. A change or a finished request only means "work it out again". Per strategy it opens the session as the strategy's owner (`AppRestarted` once per run, `AccountChanged`, `ConnectionReturned`; `ConnectionLost` when offline), claims every sendable entry 180 ms after the strategy last changed, at most 40 and those first sent under the same client id, and sends the claim as one `ops:applyBatch` opted in to `ACCOUNT_MISMATCH`. The connection, sign-in count and account are compared with the claim's at the moment of the call; if any changed, the claim is given back unsent. An answer is that strategy's to write before anything else is done for it, through holds, and a write the disk refused is tried again with a growing delay while other strategies go on. In send mode the shadow opens no sessions: it records results into the session the sender opened (`StoreSessions`). Work that waits for a result from the server waits while the editor does not show that strategy, and nothing yet lifts edit access lost after `FORBIDDEN`. Results that arrive while the strategy has its own work queued or landed are not compared (`this device's own work was still on its way`), and the run fails if work is left in a queue at the end.

Its steps:

- `{"storeMove": id, "by": [dx, dy]}` commits a whole-row move of element `id` to the store, at the revision the store holds, as the account signed in; with `"startingWith": true`, of the first element whose id starts with `id`.
- `{"breakConvexSignIn": true}` gives the Convex client a token the server refuses, the way an expired sign-in the app cannot refresh looks; `{"restoreConvexSignIn": true}` has the app set its Convex sign-in up again.
- `{"holdSender": true}` and `{"releaseSender": true}` hold sending and let it go again; answers already received are still written while it is held.
- `{"waitStoreSent": seconds}` waits until every queue is empty and no landed work waits for a result; with `"landed": "may wait"` landed work may still wait.
- `{"expectStoreNeedsYou": true}` logs every entry that needs the user, with the queue's reason, and fails if there is none; `{"storeUseCloud": true}` takes the cloud's version of each.
- `{"storeSyncState": true}` logs each cloud strategy's sync state for the account signed in, whose work it is, and the sender's state.
- `{"killNow": true}` ends the app at once, the way a crash does.
- `{"signOut": true}` signs out through the app's own confirmation; `{"signIn": "second"}` signs in to `--second-account` (Linux).

The scripts: `cloud-store-send.json` (ops sent and the store equal to the server), `cloud-store-send-owner.json` with `cloud-store-send-teammate.json` (a teammate's edit first, so the owner's op needs the user), `cloud-store-send-offline.json` through `linux-cloud-store-offline.sh <exe dir> <out> <account> <script> send` (an answer lost, the same op id resent and answered as already applied), `cloud-store-send-restart-before.json` then `cloud-store-send-restart-after.json` with `--hive-store` (unsent work sent once after a restart), `cloud-store-send-account.json` with `--second-account` (nothing sent for another account, sent once the owner is back), `cloud-store-send-closed-before.json` then `cloud-store-send-closed-after.json` through `linux-cloud-store-offline.sh <exe dir> <out> <account> <script> send <store>` (saved work sent with no editor open, then a move made offline sent once the connection is back), and `cloud-store-send-expired.json` (an expired sign-in during a send: no call storm, sent once signed in again).

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
