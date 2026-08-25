# Delivery gate: verify and babysit page-scoped sync

Open this file only after the automated gate in
[`server_side_sync_boundaries_handoff.md`](server_side_sync_boundaries_handoff.md)
passes. This is the final sequence. The work is incomplete until the last
criterion passes.

## Run the visible proof with Computer Use

Automated tests establish the contract. The visible proof establishes that the
app keeps its promise.

Launch two clients with independent local persistence:

- Client A: `fvm flutter run -d macos`
- Client B: `fvm flutter run -d chrome`, or a second physical device if the web
  build cannot complete the current auth flow

Two `open -n` copies of the macOS app are not independent. They share the same
Application Support directory and Hive boxes, so that setup cannot prove
remote convergence.

Use the Computer Use skill for the native Icarus window. Start with a fresh app
state read, prefer accessibility elements, and fetch fresh state after every
action before reusing an element index. Use the product browser controls for
the web client when available. Screenshots support the written observations.
They do not replace them.

Ask Dara to take over for credentials or an unexpected permission prompt.
Continue once both clients show the same signed-in cloud strategy.

Create a strategy named `SYNC BOUNDARY PROBE` with pages `A ACTIVE` and
`B INACTIVE`. Give each page a distinct text element. Add an image or lineup
image to page B so asset scoping is exercised.

Run and record these scenarios:

| Scenario | Client actions | Required visible result |
| --- | --- | --- |
| inactive-page isolation | A stays on page A. B moves an element and edits a lineup on page B. | A's canvas does not rehydrate or flicker. Its page A content stays unchanged. Switching A to B reveals B's accepted edits. |
| same-page convergence | Both clients open page A and edit different entities. | Both edits land and both clients converge. The sync chip reaches `Synced` only after acknowledgements. |
| same-entity conflict | Both clients edit one entity from the same revision. | One edit rejects or rebases through the explicit conflict flow. The losing intent is visible. No silent overwrite occurs. |
| page structure | B renames, adds, reorders, then deletes a non-active page. | A's page list updates through the shell. The active canvas changes only if its page disappears. |
| page switch with pending work | A edits page A and immediately switches to B. | Navigation stays responsive. Page A intent remains queued or lands. Returning to A shows the intended content. |
| full round-trip | Export the cloud strategy, import it into a clean local library, then export it again. | Pages, settings, entities, lineups, and media match semantically. |

For the restart proof, temporarily disconnecting the Mac is a network-setting
change. Computer Use must ask for confirmation at action time. With approval:

1. Disconnect after both clients have loaded.
2. Edit page A and verify `Offline` or `Attention`, never `Synced`.
3. Quit and reopen Icarus.
4. Verify the pending edit and status survived.
5. Reconnect and verify the same op lands once.

Without approval, run the equivalent durable-outbox provider test and mark the
visible restart scenario as not run with that exact reason.

Done when every scenario has an observed result, the setup identifies both
clients, and any skipped path has a concrete reason.

## Measure the resource boundary

Open the linked Convex development dashboard and isolate a short test window.
Compare ten element moves on an active page in a two-page strategy with ten
moves on the same-sized active page in a many-page strategy.

Record query calls, rows read, bytes read or returned, and mutation conflicts
where the dashboard exposes them. The result should scale with active-page
content, not inactive page count. Report observed numbers. Set no invented
percentage target.

Done when the evidence names the function, test window, page and entity counts,
observed metrics, and any dashboard metric that was unavailable.

## Open the PR

Refresh `origin/icarus-cloud` before opening the PR. Rebase or merge only with
the repository's normal policy. Open the PR against `icarus-cloud`, not `main`.

The body must include:

- the shell and active-page boundary;
- the write matrix and replay rule;
- the development deployment reset;
- automated command results;
- Computer Use scenario results;
- Convex resource observations;
- known follow-ups outside this assignment.

Done when the PR exists against the correct base and its body contains the
actual proof results rather than a checklist of work still to run.

## Babysit the current PR head

Invoke the `github-pr-babysitter` skill. Record the PR number, URL, branch,
current head SHA, checks, review bots, and thread-aware review state. Poll active
reviews instead of reading an older badge as current.

For every new head:

1. Wait for the current bot run and CI.
2. Read review threads with `isResolved` and `isOutdated` data.
3. Fix narrow actionable findings.
4. Re-run proof proportional to the change.
5. Commit only the intended files and push.
6. Trigger the documented re-review mechanism.
7. Confirm a new review actually starts for the new SHA.

For Greptile, green means a current-head 5/5 result. A top-level summary is
insufficient while an actionable thread remains. Leave the PR unmerged.

Done when CI passes on the current head, the latest automated review applies to
that head, no actionable unresolved thread remains, the branch is clean and
pushed, and Dara receives the PR URL, head SHA, review result, and proof run.
