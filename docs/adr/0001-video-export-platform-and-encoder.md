# ADR 0001: Video export ships Windows-only, encoding via a bundled ffmpeg.exe

**Status:** Accepted (2026-07-31)
**Feature:** Video sequencing export (pages → .mp4)

## Context

Icarus needs to export a strategy's pages as an .mp4 slideshow. The app is
Windows-first (MSIX / Microsoft Store); the existing screenshot and `.ica`
export flows are already gated to Windows in the UI.

The Flutter mp4-encoding landscape as of mid-2026:

- `ffmpeg_kit_flutter` (Arthenica) is retired and discontinued on pub.dev.
  The official successor `FFmpegKitNext` is source-only and has no Windows
  support.
- The maintained fork `ffmpeg_kit_flutter_new` does now support Windows
  x86_64, but its LGPL variants lack x264 and it downloads binaries at build
  time; the x264-bearing flagship variant is GPL v3, which would make Icarus
  GPL.
- `flutter_quick_video_encoder` (AVAssetWriter / MediaCodec) has no Windows
  backend and none is planned.
- No pure-Dart H.264/mp4 encoder exists. The pure-Dart fallback is animated
  GIF via the `image` package (256 colors, large files).
- MSIX apps packaged with the `msix` pub package declare `runFullTrust`, so a
  full-trust process may spawn executables bundled inside the package.
  The install directory is read-only; output must be written to user paths
  (which the FilePicker save flow already guarantees).

## Decision

1. **v1 targets Windows only**, matching the existing export gating. The
   encoder sits behind a small `VideoEncoder` abstraction so macOS
   (`flutter_quick_video_encoder`) or other backends can be added later.
2. **Encoding is done by an LGPL-configured `ffmpeg.exe` bundled in the MSIX**
   and invoked with `Process.run`/`Process.start`. No in-process ffmpeg
   library dependency.
3. **H.264 is produced via ffmpeg's Media Foundation encoder (`h264_mf`)**,
   which is available in LGPL builds and uses OS hardware/software MFTs —
   avoiding both x264 (GPL) and codec-licensing entanglement in our binary.
   If `h264_mf` initialization fails on a given machine, fall back to
   `-c:v mpeg4` (still an .mp4 container, universally decodable).
   Always pass `-pix_fmt yuv420p` for player compatibility.

## Consequences

- Licensing stays clean: LGPL obligations attach to the ffmpeg binary
  (redistribute source offer + attribution), not to Icarus.
- Debuggable: the exact ffmpeg command line can be logged and reproduced in a
  terminal.
- Adds tens of MB to the installer (see ADR 0004 for how the binary is
  sourced and pinned).
- Non-Windows platforms keep the existing "only supported in the Windows
  version" toast for this feature until a second backend lands.
