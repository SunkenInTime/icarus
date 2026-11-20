---
name: delete-comment
description: Remove the comments from one area of Icarus, keep what they knew in issues and ADRs, and lower the comment baseline.
disable-model-invocation: true
---

# Delete comments

Icarus is moving to code without comments. `tool/comments.mjs check` runs in CI's analyze lane and holds every file to the comment count in `tool/comment_baseline.json`: a file may lose comments, never gain them, and a new file starts at zero. Each run of this skill takes one area to fewer comments, keeps the knowledge they held, and lowers the baseline.

## 1. Pick the area

Use the path the user named. With none, run `node tool/comments.mjs stats` and take the subsystem with the most comment lines that no open PR touches. One subsystem per PR keeps the ADR readable and the review small.

## 2. Sort every comment

`node tool/comments.mjs list <paths>` prints one JSON line per comment block, with `id` (`path:line`), `lines`, `ownLine` and `text`. Tool directives (`// ignore:`, `// eslint-disable`, `#Requires`, …) and formatter guards (an empty `//` at the end of a code line) are left out; they stay.

Read each block with the code around it and give it one category. Ask: if this comment vanished, what would the next reader lose?

- **tautology**: nothing. The name, the types, the next lines or the assertion below already say it. Section banners. Test narration of the next call.
- **stale**: no longer true. Code that is gone, behaviour the code no longer has, commented-out code, a done TODO, history ("used to", "Before,", "after the refactor"). Open the code to confirm.
- **excuse**: it lets a weak implementation stand: a workaround, `TODO`/`FIXME`, a sleep or "wait a frame" standing in for an event, a swallowed error, a copy that must be "kept in sync" by hand. Name the code change that would make it unnecessary.
- **decision**: a non-obvious choice where real alternatives existed, with a reason the code can't show. Without it, someone would "fix" the code and break something.
- **contract**: what something means or promises (an enum value, a unit, what null means, an edge case) that the name and types don't carry.

Done when every id from `list` has exactly one category. For more than about 400 blocks, split the list by file across Opus subagents, give each these definitions and a JSONL output to fill, and validate that every id came back once. Their categories are hearsay: read every stale and excuse call yourself, and a sample of the rest.

## 3. Act on each category

- **tautology, stale**: delete.
- **excuse**: check the claim in the code, then file one GitHub issue per fix (several comments excusing the same hack share one, as a checklist). The issue quotes the comment, links its line at the base commit's SHA (the line is gone after the PR), and says what to change. Then delete.
- **decision**: write it into an ADR for the subsystem, `docs/adr/NNNN-<subsystem>-implementation-decisions.md`, numbered after the highest in `docs/adr/` (`0008-video-export-implementation-decisions.md` is the model): each decision with its reason, naming the code it governs, grouped by component. Check each fact you write against the code. Then delete.
- **contract**: turn it into code where you can: a name that says it, a type that enforces it, or a test that pins the promise, then delete it. Otherwise leave it; the baseline keeps it from growing.

Write the ids to delete into a file, one per line, and run `node tool/comments.mjs remove <file>`. It deletes only those blocks, deletes files left empty, and refuses to write a file whose code would change.

## 4. Prove nothing but comments moved

All of these hold before the PR opens:

- `node tool/comments.mjs same-code origin/main` passes: outside the contract rewrites, the diff is comments, whitespace and Dart imports nothing uses any more.
- `fvm flutter analyze` shows nothing new against main except two expected kinds: an `unused_import` for an import that only a doc link (`[SomeType]`) used, which you delete; and `empty_catches` where the deleted comment excused an empty `catch`, which its issue or ADR now covers.
- The checks for each language touched pass: `fvm flutter test` for the files it touches, `npx tsc --noEmit` and `npm run test:convex` for `convex/`, `cargo test --locked` for `native/replay`.
- `node tool/comments.mjs baseline` lowers the baseline, and `node tool/comments.mjs check` passes.

## 5. Open the PR

The description gives the count per category, links every issue filed and the ADR, and says which contracts were turned into code. `convex/` changes deploy to production when merged, even when they are comment-only; say so in the description.
