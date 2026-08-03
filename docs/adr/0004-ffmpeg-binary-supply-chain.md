# ADR 0004: ffmpeg.exe is fetched at build time in CI, pinned and checksummed

**Status:** Accepted (2026-07-31)
**Feature:** Video sequencing export (pages → .mp4)

## Context

ADR 0001 decided to bundle an LGPL `ffmpeg.exe` inside the MSIX and invoke it
as a child process. The binary is ~25–80 MB depending on build configuration.
Options considered: commit it to the repo (or Git LFS), download it on first
use at runtime, or fetch it during the build.

Note: the common prebuilt Windows ffmpeg distributions (gyan.dev, BtbN
"release" builds) are **GPL** builds (they include x264). An LGPL-configured
Windows build must be sourced or built ourselves; `h264_mf` (ADR 0001) does
not require any GPL component.

## Decision

1. **The build/packaging pipeline downloads a pinned LGPL ffmpeg Windows
   build** (exact URL + SHA-256 checksum recorded in a script committed to the
   repo) and places it under the Windows assets included in the MSIX.
2. The same script is runnable locally (e.g. as part of the Windows build
   step) so developers get the binary without manual steps; the download is
   skipped when the checksummed file is already present.
3. The app resolves the binary relative to the executable directory at
   runtime and **writes all ffmpeg output to user-chosen / temp paths**, never
   the read-only `WindowsApps` install directory.
4. ffmpeg attribution and the LGPL source-availability notice are added to the
   app's licenses/about surface.

## Consequences

- The repo stays small; the ffmpeg version is reproducible and upgraded by
  editing one pinned URL + checksum.
- The Store packaging workflow (MSIX build) gains one step and must be
  updated — the recent "Build Store app before MSIX packaging" work is the
  place to hook in.
- No runtime network dependency and no Store-policy concerns about
  downloading executables post-install.
- If no suitable prebuilt LGPL Windows binary can be sourced, the fallback is
  building ffmpeg LGPL ourselves in CI (one-time setup cost) — the decision
  to fetch-at-build-time is unchanged.
