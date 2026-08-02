import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

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

  /// Updates the persistent tree and captures it as a PNG without a fixed
  /// settling delay. Any work that was synchronously or microtask-scheduled
  /// by the update is flushed before capture.
  Future<Uint8List> capture(Widget widget) async {
    final image = await _captureImage(widget);
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
  Future<Uint8List> captureRawRgba(Widget widget) async {
    final image = await _captureImage(widget);
    try {
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
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

  Future<ui.Image> _captureImage(Widget widget) async {
    _checkNotDisposed();
    _updateWidget(widget);
    await _flushPendingFrames();
    return _repaintBoundary.toImage(pixelRatio: pixelRatio);
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
          child: rootWidget,
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
  }) async {
    if (_disposed) return;
    _disposed = true;
    final drainFrame = waitForFrame ?? () => WidgetsBinding.instance.endOfFrame;

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
