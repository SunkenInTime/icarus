# ADR 0008: Video export implementation decisions

**Status:** Accepted (2026-11-20)
**Feature:** Video export (`lib/services/video_export/`, `lib/widgets/dialogs/export_video_dialog.dart`)

These decisions used to be comments beside the code. ADRs 0001–0007 cover the platform, transitions, settings, the ffmpeg supply chain, quality presets and transparent video. This one keeps the smaller choices inside that design, each with the reason it was made, so that nobody "fixes" one and breaks the export.

## Desktop encoding (ffmpeg)

- **Frames reach ffmpeg as raw RGBA through one long-lived process** (`FfmpegPngSequenceWriter`). Flutter's PNG encoding is expensive at 1080p, raw readback is much faster, and the native process encodes one frame while Flutter prepares the next, with no raw frames kept on disk.
- **Draining ffmpeg's pipes gives up after two seconds** (`FfmpegPngSequenceWriter._drainOutput`). The pipes outlive a process that refused to die.
- **The bundled ffmpeg next to the executable is used** (ADR 0004). A `PATH` install is a fallback for local development on macOS and Linux only. Windows has no `PATH` fallback because `where` searches the working directory first, so a planted `ffmpeg.exe` could be launched. `scripts/fetch_ffmpeg.ps1` stages the bundled binary.
- **ffmpeg never writes to the path the user chose.** It writes `<output>.icarus-partial.mp4`, because `-y` truncates its target at once and a failed or cancelled encode must not destroy a video already there. The finished file is renamed over the destination (`_replaceDestination`). The rename is within one directory, so it is atomic. There is no copy fallback: a copy truncates the destination first, and a failure halfway through would damage the very video the partial file protects. If the rename fails, the error reaches the user and the old video is untouched.
- **The muxer is named (`-f mp4`), not inferred from the path**, because the path ends in `.icarus-partial.mp4`.
- **The concat playlist repeats its final still**, because the concat demuxer ignores the last entry's duration otherwise (`FfmpegVideoSink`). Some ffmpeg builds then give the repeat the same duration and hold the last page twice, so the encoder passes `-t` with the duration `VideoExporter` planned.
- **Progress reserves a slot for every ffmpeg run the encoder might make.** A size retry or Max's codec fallback continues from halfway instead of making the progress bar jump backward.
- **`FfmpegVideoSink.cancel` only interrupts the processes; `close` waits for them to exit** before deleting the temp folder, because on Windows the delete races a process that is still exiting. A failure to delete that folder is ignored: orphaned frames are better than hiding the export's real result.
- **Rendering gets 85% of the progress bar** (`VideoExporter`), because rendering frames takes most of the time and encoding is the short tail.

## Browser encoding (WebCodecs)

- **A keyframe at least every two seconds**, so players can seek inside a long hold. **Each held page (a run longer than one frame) opens on a keyframe** so it starts crisp and seeks cleanly. Single-frame transition frames are not keyed, which would spend the bitrate on I-frames.
- **`addFrame` waits once the encoder holds 8 frames**, so a fast renderer cannot pile frames up in memory.
- **The default bitrate is 8 Mbps at 1080p30**, the desktop Max preset's H.264 rate, scaled by pixel count. 60 fps gets 1.5× rather than 2×: consecutive frames differ less, and held pages cost almost nothing either way.
- **Profiles are tried in order H.264 High, Main, Constrained Baseline.** In Chrome, High needs a hardware encoder; the software encoder (OpenH264) only does Constrained Baseline.
- **The MP4 has no composition offsets, so chunks must arrive in presentation order.** An encoder that reorders frames (B-frames) fails the export instead of producing a video that plays frames out of order. The MP4 also carries a single `avcC`, so the export fails if the encoder changes its parameter sets mid-stream.

## Muxing and timing (both platforms)

- **The timescale is `fps × 1000`**, so every frame duration is a whole number of ticks. The encoders keep the running sum of planned durations rather than adding rounded ones, so rounding never accumulates.
- **`moov` is built twice** (`mp4_muxer.dart`). The single chunk offset depends on `moov`'s size, but the size doesn't depend on the offset's value, so a first pass with offset 0 measures it.
- **64-bit fields are written as two 32-bit halves**, because `ByteData.setUint64` is unsupported when compiled to JavaScript.
- **The muxer test encodes with no B-frames, an access unit delimiter before each frame and an IDR every 5 frames**: the muxer writes no composition offsets, the delimiters let the stream split cleanly, and several IDRs give `stss` several entries.

## Transparent video (QuickTime Animation)

- **Transparent export is QuickTime Animation (`rle `, 32-bit ARGB), encoded in Dart** (`QuickTimeAnimationEncoder`). DaVinci Resolve and Clipchamp both composite its alpha correctly; VP9 WebM loses half-transparent pixels in Resolve, and ProRes 4444 breaks in Clipchamp. Being pure Dart, it needs neither ffmpeg nor the browser's encoder, and desktop and browser produce the same file. On the web the browser downloads it.
- **The `.mov` boxes match ffmpeg's own output for this codec** (`MovAnimationMuxer`), because that is the layout Resolve and Clipchamp read with its alpha. The frame coding follows ffmpeg's `qtrle` decoder (libavcodec/qtrle.c).
- **The video is constant frame rate**, as editors expect. A repeated frame that changes nothing costs a few bytes, a keyframe every two seconds keeps seeking quick, and **the last frame is always a keyframe**, because Clipchamp ends a QuickTime Animation clip at its last keyframe and would cut off what follows.
- **The file is written beside the destination and renamed over it**, as with ffmpeg. The cancel check runs after the write and before the rename, because the rename is the only step that touches the destination.
- **A transparent export runs at the Social preset and plays at 30 fps.** It is lossless, so the presets' size targets don't apply, and the dialog dims the presets and keeps them out of clicks and focus.

## Quality presets

- **Potato drops to 720p only once its duration-derived bitrate reaches the readable floor.** At every higher bitrate tested, 1080p kept more map and label detail for the same size target.
- **Very long exports are clamped to the readable floor rather than refused** (`initialVideoBitrate`).
- **The size targets (10 MiB, 20 MiB) aim at useful sharing sizes but are not an export gate.** Discord's attachment limits vary by account and server and change over time.

## What gets rendered

- **The export reads the strategy with the share link's token when it was opened through a link** (`readSavedStrategy`), because a signed-out reader's only access is that link.
- **Captures get copies of a local strategy's pages and drawings, never the library's own objects.** A capture rebuilds drawing paths at 1920×1080; on shared objects the editor would then draw strokes at the capture's scale.
- **`resolvePageImages` treats every asset as loaded and no upload as queued**, because the whole strategy was just read: an export has already waited for this device's uploads to land, and a preview shows the ones that have.
- **Rendering runs inside `CoordinateSystem.runInCapture`**, so it uses the capture's coordinates while the editor keeps its own, whatever the editor does meanwhile.

## The export dialog

- **Where the file goes is settled before rendering**, so a dismissed save dialog, or a browser that cannot encode video, costs nothing.
- **A second tap on Export starts nothing** (`_exportRunning`), because the button stays enabled while the file picker is open.
- **Closing the dialog cancels a running export**, so frames never keep rendering and the encoder never keeps running in the background. If the export then fails, the user is told it was cancelled: closing mid-preparation can fail the work it cut short, and stopping is what they asked for. A cancel that arrives while the export is wrapping up still wins, and nothing is saved.
- **A failed map geometry load doesn't stop the dialog.** The provider reports the failure itself, and the exporter refuses movement on maps that need navigation data it doesn't have.
- **On the web the progress view says to keep the tab open**, because a hidden tab stops painting frames and the render stalls.
- **Layout:**
  - The content gets a fixed width (dialog width minus 48), because `ShadDialog` shrink-wraps to intrinsic widths, which cannot lay out `Expanded`/`Spacer` rows or the slider. `UploadImageDialog` uses the same idiom.
  - The preset row sits in `IntrinsicHeight`, so the three cards share the tallest card's height; without it the scrollable dialog hands the row an infinite height.
  - The summary shares the bottom row with the buttons, aligned to their bottom edge, and the dialog's own actions slot stays empty.
