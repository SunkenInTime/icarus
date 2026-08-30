# Icarus Online Beta Readiness

Last refreshed: 2026-08-30

This is the release gate for the first invite-only Icarus Online beta. It is a
checklist, not a backlog. A checked item needs current evidence from the build
being released.

## Decision Today

The current release candidate is ready for internal testing, but do not invite
outside testers yet.

The transport, authorization, durable outbox, native restart, and R2 server
boundaries now have evidence. The remaining blocker is narrower: finish the
Windows public-upgrade job on the pull-request SHA, then complete one visible
two-client run containing a real UI write, offline restart, rejection, media
round trip, sign-out, and sign-in. Automated tests prove those state machines,
but they do not prove that every on-screen state is legible in the built app.

## 2026-08-30 Release-Candidate Receipt

This receipt belongs to the release-candidate branch cut from
`icarus-cloud` at `ce9beec189e35f48cced623e161aa55f2642e782`.
Freeze the shippable SHA to the pull-request head after every required check is
green. On pull requests every CI job explicitly checks out that source SHA,
instead of GitHub's temporary merge commit, and the Windows job includes it in
the artifact name.

Completed against the current candidate:

- `npx tsc --noEmit` passes.
- `npm run test:convex` passes 30 tests, including three A/B/C access-boundary
  tests and durable delete cleanup for collaborators and share links.
- The scrubbed Convex contract snapshot is current. The strict audit passes 42
  public functions and 34 error codes.
- `fvm flutter test` passes all 387 tests. The suite covers persistence before
  send, in-flight restart replay, retry exhaustion, manual retry identity,
  rejected-op reconciliation, auth setup incidents, and local fallback when
  cloud becomes unavailable.
- `fvm flutter analyze --no-fatal-infos` has no errors and six existing info
  notices.
- The web release build and the macOS release build complete. macOS requires
  `--no-tree-shake-icons`, matching the existing CI builds.
- Two fresh Supabase users completed real password authentication and
  `users.ensureCurrentUser` against the deployed Convex development backend.
- A deployed A/B/C contract run proved private isolation, viewer read-only,
  editor mutation and readback, revoked-link denial for a new user, durable
  redeemed access for an existing collaborator, and inherited folder roles.
  The third identity was synthetic because Supabase rate-limited creation of a
  third disposable email account.
- A live R2 run proved presigned upload, public byte readback, rejection of a
  tampered object key, rejection of completion for a missing object, and test
  cleanup. This does not yet prove the full built-app media queue.
- Computer Use verified an isolated macOS 4.3.7 release app with a unique bundle
  identifier. Persisted auth reconnected after a full process restart, a cloud
  Strategy appeared through the live subscription, a server rename arrived
  without reload, and the Strategy opened in the editor with **Synced** visible.
  The isolated app did not touch the normal Icarus application-support path.
- The Windows CI gate now installs public 3.2.3 and imports the real v35
  `base-test.ica` fixture pinned to repository commit `fddec2b0`. It verifies
  the GitHub release asset digest and fixture SHA before executing either
  input, then requires a responsive app window and a non-empty Strategy library.
  A read-only probe compares stable Strategy, page, and entity identities and
  ordering, then normalizes the public library through the current migration
  path and compares its complete semantic fingerprint after the candidate
  upgrade and after rollback. The rollback must also leave the candidate Hive
  bytes untouched. The installer and JSON receipt are uploaded together.

Known verification limitations:

- Computer Use could focus the macOS Flutter name field, but native keyboard
  and clipboard injection did not reach Flutter's text controller. The live
  Strategy was therefore created through the authenticated backend before its
  subscription, restart, update, and editor readback were verified visually.
- The collaborative browser could serve and navigate the release web build,
  but Flutter's semantics snapshot timed out. The earlier 2026-08-25 real web
  sign-in and write/readback receipt remains the current visible web proof.
- R2 upload jobs are reconstructed from local page media after restart rather
  than persisted as an independent durable job table. The built-app
  upload/restart/download/export path remains unchecked below.

## Release Rule

The beta is ready when every P0 item is checked against one release candidate,
there are no unresolved data-loss or access-control findings, and the tester
can understand every non-synced state without opening logs.

P1 items should be complete before inviting people who will not have a direct
support channel. P2 items can follow the invite-only beta.

## P0: Protect the Library

- [x] The Convex client and deployed server complete authentication without a
      fatal protocol error or reconnect loop.
  - Evidence: production web build verified on 2026-08-25 with real sign-in,
    authenticated strategy create, second-page edit to **Synced**, reload,
    fresh sign-in, server readback of both pages, and test-data cleanup. No new
    protocol error or reconnect loop appeared in the post-fix console.
- [ ] A local-mode library created on the current public build opens unchanged
      after installing the beta.
  - Evidence: the Windows pull-request job now automates public 3.2.3,
    the pinned v35 `base-test.ica`, the exact pull-request SHA, current-version
    semantic comparison, and read-only Hive probes. Check this item only after
    that job is green on the frozen SHA.
- [ ] Signing in does not move, delete, or rewrite local strategies unless the
      user explicitly starts a migration.
  - Evidence: pending; compare library counts and exported fixtures before and
    after sign-in.
- [ ] A cloud strategy survives create, edit, app restart, sign-out, and sign-in
      with pages, drawings, agents, abilities, lineups, media, and ordering
      intact.
  - Evidence: pending; attach the exported `.ica` before and after the cycle.
- [ ] Exporting then importing both a local strategy and a cloud strategy loses
      no supported data.
  - Evidence: pending; compare canonical exports, allowing only documented
    identity fields to differ.
- [ ] An offline edit remains visibly pending, lands after reconnect, and still
      lands after the app is restarted while offline.
  - Evidence: durable outbox tests pass the restart-before-send and
    restart-in-flight boundaries. The three visible status receipts are still
    required.
- [ ] A rejected or exhausted op never produces a **Synced** state. The user
      sees an actionable error before leaving the strategy.
  - Evidence: retry-exhaustion and rejected-op provider tests pass and preserve
    immutable operation identity. A built-app rejection receipt is still
    required.

## P0: Prove the Online Loop

- [ ] Account A can create a cloud strategy and Account B cannot see it before
      it is shared.
- [ ] Account A can create a view-only link. Account B can join and view every
      page but cannot mutate the strategy.
- [ ] Account A can create an editor link. An edit from Account B appears for
      Account A without either client reloading or losing local input.
- [ ] Simultaneous edits take the documented conflict path. No accepted edit is
      silently overwritten, and uncertainty is visible.
- [ ] Disabling a share link blocks a new Account C from joining while Account
      B keeps the access already granted.
- [ ] Removing or downgrading an existing collaborator, if exposed in this
      beta, changes their effective access on the next protected operation.
- [ ] Shared folders apply the correct effective role to their strategies,
      including inherited editor access.

Contract evidence for this section is green in `convex/accessControl.test.ts`
and in the deployed development backend. Product evidence still requires one
screen recording with two clean browser profiles or two installed clients,
plus the release commit and Convex deployment name.

## P0: Platform and Failure Checks

- [ ] macOS release build completes the full local and cloud smoke path.
- [ ] Windows release build completes the full local and cloud smoke path.
- [ ] Web release build completes the authenticated second-client smoke path.
- [ ] Expired auth, revoked auth, unavailable Convex, and unavailable media
      storage each produce an honest on-screen state and recover without an app
      restart.
- [ ] Cloud media upload, retry, restart recovery, download, export, and cleanup
      are verified against the configured R2 bucket and public domain.
- [ ] A rollback build can still open the untouched local library. If cloud data
      cannot be read by the rollback build, the release notes say so plainly.

## P1: Make the Beta Legible

- [ ] Signed-out Cloud and Shared destinations lead to one obvious login action.
- [ ] Empty Cloud has a create-strategy action; empty Shared has an add-by-link
      or code action.
- [ ] Auth, library navigation, sharing, sync status, and recovery controls have
      stable semantics and automation keys.
- [ ] Share copy says **Disable link**, not delete or remove access, and explains
      that existing collaborators keep access.
- [ ] The web build identifies itself as beta and points desktop-primary users
      to a stable installer.
- [ ] Every beta tester has a visible way to report a problem with app version,
      platform, and sync state attached.

## P2: After the Invite-Only Beta Starts

- [ ] Decide whether share-link expiration belongs in the product.
- [ ] Add collaborator management if testers need remove/downgrade controls.
- [ ] Automate stale media cleanup and document its retention window.
- [ ] Add operational alerts for repeated protocol failures, rejected ops, and
      media jobs that exhaust retries.
- [ ] Define free storage and usage limits from observed beta use instead of
      guessing before there is real usage data.

## Automated Gate

Run from the repository root on the exact release commit:

```sh
npx tsc --noEmit
npm run test:convex
npm run snapshot:convex-contract:check
npm run audit:convex-contract
fvm flutter analyze --no-fatal-infos
fvm flutter test
fvm flutter build web --no-wasm-dry-run --no-tree-shake-icons
fvm flutter build macos --no-tree-shake-icons
```

On the pull request, CI also builds the Windows installer, runs
`scripts/test_online_beta_windows_upgrade.ps1`, and uploads the installer plus
its evidence JSON under an artifact name containing the exact source-branch
commit SHA. Every CI job explicitly checks out that same SHA.

Expected on 2026-08-29: no analyzer errors, six existing info notices, 387
Flutter tests green, 30 Convex tests green, TypeScript green, the contract audit
green, and release builds green. These checks are necessary, but they do not
replace the visible online-loop proof.

## Computer-Use Verification Path

Use clean profiles so cached auth and local Hive data cannot make the test pass
by accident.

1. Start Client A signed out. Confirm the local library and `.ica` import still
   work before touching online mode.
2. Sign in as Account A. Create a cloud strategy with at least two pages, one
   drawing, one agent, one ability, one lineup, and one image.
3. Open Client B in a separate clean profile and sign in as Account B. Confirm
   the strategy is absent before sharing.
4. Share view-only, join from B, and attempt each visible mutation. No mutation
   may reach the server.
5. Share editor, edit from B, and watch A. Repeat in the other direction while
   both clients have unsaved local input.
6. Take B offline, edit, restart B, reconnect, and wait for the pending op to
   land. Verify both clients and the sync-status surface agree.
7. Disable the link, then attempt a fresh join from clean Account C. Confirm B
   retains existing access.
8. Restart both clients, export the strategy, import it locally, and compare the
   result with the cloud copy.
9. Save the recording, release commit, deployment name, platform versions, and
   any console/server errors next to the checked items above.

Stop immediately on silent data loss, a false **Synced** state, an access-control
bypass, or a protocol reconnect loop. Preserve the clients and server state for
diagnosis instead of continuing the script.
