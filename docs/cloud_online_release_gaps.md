# Icarus Online Beta Readiness

Last refreshed: 2026-08-25

This is the release gate for the first invite-only Icarus Online beta. It is a
checklist, not a backlog. A checked item needs current evidence from the build
being released.

## Decision Today

Do not invite outside testers yet.

The local automated baseline is healthy: the Flutter suite passes, Convex
TypeScript passes, and the web release build completes. The web client's
authentication protocol mismatch is fixed: a production web build completed a
real email/password sign-in, authenticated Convex read and write, a second-page
edit that reached **Synced**, and a reload/readback cycle without a fatal
protocol error or reconnect loop. The temporary strategy was deleted after the
proof.

The remaining blocker is the complete two-client and failure-recovery path
below. One healthy authenticated client proves the transport boundary, but it
does not yet prove sharing, access control, conflicts, offline recovery, media,
or round-trip fidelity.

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
  - Evidence: pending; record the public version, beta commit, and fixture.
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
  - Evidence: pending; capture the status chip before restart, after restart,
    and after the op lands.
- [ ] A rejected or exhausted op never produces a **Synced** state. The user
      sees an actionable error before leaving the strategy.
  - Evidence: pending; force a rejection and an exhausted retry path.

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

Evidence for this section: one screen recording with two clean browser profiles
or two installed clients, plus the release commit and Convex deployment name.

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
fvm flutter analyze
fvm flutter test
npx tsc --noEmit
fvm flutter build web --no-wasm-dry-run --no-tree-shake-icons
```

Expected on 2026-08-25: no analyzer errors, six existing info notices, all
Flutter tests green, TypeScript green, and the web release build green. These
checks are necessary, but they do not replace the online-loop proof.

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
