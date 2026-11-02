import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/services/app_assets.dart';
import 'package:icarus/services/video_export/video_export_errors.dart';
import 'package:icarus/widgets/asset_svg.dart';

/// Renders a sequence of widgets through one detached Flutter render tree.
///
/// Unlike one-shot screenshot helpers, this keeps elements, render objects,
/// decoded images, and other widget state alive between frames. Call
/// [prepare] when a frame introduces new asynchronous assets, then use
/// [capture] for frames whose dependencies are already warm.
class PersistentOffscreenRenderer {
  PersistentOffscreenRenderer({
    required this.targetSize,
    this.pixelRatio = 1.0,
    this.wrapWidget,
    this.waitForFrameData,
    this.isCancelled,
    this.onWaitingForPictures,
    this.pictureStallLimit = const Duration(seconds: 30),
  })  : assert(pixelRatio > 0),
        _repaintBoundary = RenderRepaintBoundary(),
        _focusManager = FocusManager(),
        _frame = ValueNotifier<Widget>(const SizedBox.shrink()) {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    _positionedBox = RenderPositionedBox(
      alignment: Alignment.center,
      child: _repaintBoundary,
    );
    _renderView = RenderView(
      view: view,
      child: _positionedBox,
      configuration: ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(targetSize),
        physicalConstraints: BoxConstraints.tight(
          Size(
            targetSize.width * pixelRatio,
            targetSize.height * pixelRatio,
          ),
        ),
        devicePixelRatio: pixelRatio,
      ),
    );
    _buildOwner = BuildOwner(
      focusManager: _focusManager,
      onBuildScheduled: () => _buildScheduled = true,
    );
    _pipelineOwner = PipelineOwner(
      onNeedVisualUpdate: () => _visualUpdateScheduled = true,
    )..rootNode = _renderView;
    _renderView.prepareInitialFrame();
  }

  final Size targetSize;
  final double pixelRatio;

  /// An app shell to build once around the changing frame content.
  ///
  /// Keeping themes, providers, and navigators outside the changing frame is
  /// what lets their elements and render objects survive the whole export.
  final Widget Function(Widget child)? wrapWidget;

  /// Await queries requested by this exact mounted frame before reading pixels.
  final Future<void> Function()? waitForFrameData;

  /// Checked while a capture waits for its pictures. Once it turns true the
  /// capture throws [VideoExportCancelled] rather than wait on.
  final bool Function()? isCancelled;

  /// Hears once when a capture has waited [_waitWorthSaying] for its pictures,
  /// so the user is told why nothing is moving. A shorter wait stays quiet.
  final VoidCallback? onWaitingForPictures;

  static const _waitWorthSaying = Duration(seconds: 1);

  /// How long a capture keeps waiting with no picture arriving. A slow
  /// connection keeps landing them, so this only stops a stalled one.
  final Duration pictureStallLimit;

  final RenderRepaintBoundary _repaintBoundary;
  final FocusManager _focusManager;
  final ValueNotifier<Widget> _frame;
  late final RenderPositionedBox _positionedBox;
  late final RenderView _renderView;
  late final BuildOwner _buildOwner;
  late final PipelineOwner _pipelineOwner;

  RenderObjectToWidgetElement<RenderBox>? _rootElement;
  bool _buildScheduled = false;
  bool _visualUpdateScheduled = false;
  bool _disposed = false;

  /// Updates the persistent tree and gives newly introduced asynchronous
  /// assets a bounded opportunity to resolve before the first capture that
  /// needs them. This delay is paid per new page, not per video frame.
  Future<void> prepare(
    Widget widget, {
    Duration settleDuration = Duration.zero,
  }) async {
    _checkNotDisposed();
    _updateWidget(widget);
    if (settleDuration > Duration.zero) {
      await Future<void>.delayed(settleDuration);
    }
    await _flushPendingFrames();
  }

  /// Updates the persistent tree and waits until it has stopped loading: no
  /// image anywhere still on its way, and no rebuild pending, for two frames
  /// running. Faster than a fixed [prepare] delay when the frame's assets
  /// are already warm, and as patient when they are not, up to [timeout].
  Future<void> prepareUntilQuiet(
    Widget widget, {
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    _checkNotDisposed();
    _updateWidget(widget);
    final waited = Stopwatch()..start();
    var quietFrames = 0;
    while (waited.elapsed < timeout) {
      await _flushPendingFrames();
      final loading =
          PaintingBinding.instance.imageCache.pendingImageCount > 0 ||
              _buildScheduled ||
              _visualUpdateScheduled;
      quietFrames = loading ? 0 : quietFrames + 1;
      if (quietFrames >= 2) return;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  /// Updates the persistent tree and captures it as a PNG without a fixed
  /// settling delay. Any work that was synchronously or microtask-scheduled
  /// by the update is flushed before capture.
  Future<Uint8List> capture(Widget widget) async {
    final image = await captureImage(widget);
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('Flutter could not encode the offscreen frame.');
      }
      return byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
    } finally {
      image.dispose();
    }
  }

  /// Captures uncompressed RGBA pixels for a native encoder to consume.
  ///
  /// This avoids Flutter's comparatively expensive per-frame PNG encoding.
  /// The returned bytes are ordered top-to-bottom, four bytes per pixel.
  /// They are premultiplied unless [straightAlpha], which a frame with
  /// see-through pixels needs: encoders read RGBA as straight alpha, and
  /// premultiplied colour would darken every half-transparent pixel.
  Future<Uint8List> captureRawRgba(
    Widget widget, {
    bool straightAlpha = false,
  }) async {
    final image = await captureImage(widget);
    try {
      final byteData = await image.toByteData(
        format: straightAlpha
            ? ui.ImageByteFormat.rawStraightRgba
            : ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) {
        throw StateError('Flutter could not read back the offscreen frame.');
      }
      return byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
    } finally {
      image.dispose();
    }
  }

  /// Updates the persistent tree and captures it as an image, for a caller
  /// that draws it rather than saves it. The caller disposes the image.
  Future<ui.Image> captureImage(Widget widget) async {
    _checkNotDisposed();
    _updateWidget(widget);
    await _flushPendingFrames();
    await waitForFrameData?.call();
    await _flushPendingFrames();
    await _waitForPictures();
    return _repaintBoundary.toImage(pixelRatio: pixelRatio);
  }

  /// A picture still on its way throws no error of its own, so a capture has
  /// to look, or it would save a page with the picture missing. It waits for
  /// the frame's pictures, and throws [CaptureImagesUnavailable] if one's read
  /// fails or they stop arriving.
  Future<void> _waitForPictures() async {
    var loading = _picturesLoading();
    final sinceLastPicture = Stopwatch()..start();
    final waited = Stopwatch()..start();
    var said = false;
    while (loading.isNotEmpty) {
      if (isCancelled?.call() ?? false) throw VideoExportCancelled();
      if (!said && waited.elapsed >= _waitWorthSaying) {
        said = true;
        onWaitingForPictures?.call();
      }
      final missing = appAssets.missing.value;
      if (loading.any(missing.contains)) {
        throw CaptureImagesUnavailable.fetchFailed(
          '${loading.firstWhere(missing.contains)} has not loaded',
        );
      }
      if (sinceLastPicture.elapsed >= pictureStallLimit) {
        throw const CaptureImagesUnavailable.stillLoading();
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
      _rebuildLayoutBuilders();
      await _flushPendingFrames();
      final left = _picturesLoading();
      if (left.length < loading.length) sinceLastPicture.reset();
      loading = left;
    }
  }

  /// The mounted frame's pictures that have nothing to paint yet, by asset
  /// name, or null for a picture that isn't an asset. An [Image] builds a
  /// [RawImage] with no image until its picture is decoded.
  List<String?> _picturesLoading() {
    final loading = <String?>[];
    String? imageAsset;
    void visit(Element element) {
      switch (element.widget) {
        case AssetSvgLoading(:final assetName):
          loading.add(assetName);
        case Image(:final image):
          imageAsset = image is AssetImage ? image.keyName : null;
        case RawImage(image: null):
          loading.add(imageAsset);
      }
      element.visitChildren(visit);
    }

    _rootElement?.visitChildren(visit);
    return loading;
  }

  /// A picture under a [LayoutBuilder] can only rebuild once the builder runs,
  /// and the builder leaves that to the app's next frame. A minimized window
  /// has no next frame, so run them here, as that frame would.
  void _rebuildLayoutBuilders() {
    void visit(Element element) {
      if (element case RenderObjectElement(:final renderObject)
          when renderObject is RenderObjectWithLayoutCallbackMixin) {
        renderObject.scheduleLayoutCallback();
      }
      element.visitChildren(visit);
    }

    _rootElement?.visitChildren(visit);
  }

  void _updateWidget(Widget widget) {
    if (_rootElement == null) {
      _frame.value = widget;
      final frameHost = ValueListenableBuilder<Widget>(
        valueListenable: _frame,
        builder: (context, frame, child) => frame,
      );
      final rootWidget = wrapWidget?.call(frameHost) ?? frameHost;
      _rootElement = RenderObjectToWidgetAdapter<RenderBox>(
        container: _repaintBoundary,
        debugShortDescription: '[Icarus video export root]',
        child: Directionality(
          textDirection: TextDirection.ltr,
          // The app's bundle, so a capture finds the images the editor decoded.
          child: DefaultAssetBundle(bundle: appAssets, child: rootWidget),
        ),
      ).attachToRenderTree(_buildOwner);
    } else {
      _frame.value = widget;
    }
    _flushFrame();
  }

  void _flushFrame() {
    final rootElement = _rootElement;
    if (rootElement == null) return;

    _buildScheduled = false;
    _visualUpdateScheduled = false;
    _buildOwner.buildScope(rootElement);
    _buildOwner.finalizeTree();
    _pipelineOwner.flushLayout();
    _pipelineOwner.flushCompositingBits();
    _pipelineOwner.flushPaint();
  }

  Future<void> _flushPendingFrames() async {
    // Let completed Futures and image streams enqueue their rebuilds. Most
    // cached assets settle in this first event-loop turn.
    for (var attempt = 0; attempt < 10; attempt++) {
      await Future<void>.delayed(Duration.zero);
      if (!_buildScheduled && !_visualUpdateScheduled) return;
      _flushFrame();
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('PersistentOffscreenRenderer has been disposed.');
    }
  }

  Future<void> dispose({
    Future<void> Function()? waitForFrame,
    Duration drainTimeout = const Duration(seconds: 2),
  }) async {
    if (_disposed) return;
    _disposed = true;
    // `endOfFrame` never completes while the engine is not producing frames
    // (e.g. the window is minimized), so each drain is best-effort and bounded.
    final rawDrain = waitForFrame ?? () => WidgetsBinding.instance.endOfFrame;
    Future<void> drainFrame() =>
        rawDrain().timeout(drainTimeout, onTimeout: () {});

    try {
      // Flush callbacks registered by the last captured frame while its
      // providers and focus tree are still alive.
      await drainFrame();

      _rootElement = RenderObjectToWidgetAdapter<RenderBox>(
        container: _repaintBoundary,
        debugShortDescription: '[Icarus video export root]',
      ).attachToRenderTree(_buildOwner, _rootElement);
      _flushFrame();
      _rootElement = null;

      // Unmounting can schedule focus microtasks and widget cleanup callbacks.
      // Let both queues drain before releasing the objects they reference.
      await Future<void>.microtask(() {});
      await drainFrame();
    } finally {
      _pipelineOwner.rootNode = null;
      _renderView.child = null;
      _positionedBox.child = null;
      _repaintBoundary.dispose();
      _positionedBox.dispose();
      _renderView.dispose();
      _pipelineOwner.dispose();
      _frame.dispose();
      _focusManager.dispose();
    }
  }
}
