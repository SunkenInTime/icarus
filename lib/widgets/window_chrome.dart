import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:icarus/const/settings.dart';
import 'package:window_manager/window_manager.dart';

/// Height of the strip the app draws in place of the native title bar.
/// `macos/Runner/MainFlutterWindow.swift` centers the traffic lights on it.
const double kWindowStripHeight = 40;

/// Height of the editor's header band: the 65px map card.
const double kEditorHeaderHeight = 65;

/// Room reserved on the left for the native macOS traffic lights.
const double kMacTrafficLightInset = 78;

/// Talks to `MainFlutterWindow.swift`, which centers the traffic lights on
/// whatever band height the current screen reports.
const MethodChannel _chromeChannel = MethodChannel('icarus/window_chrome');

int _editorHeadersMounted = 0;

Future<void> _syncMacTitleStripHeight() async {
  if (!_isMacOS) return;
  final height =
      _editorHeadersMounted > 0 ? kEditorHeaderHeight : kWindowStripHeight;
  try {
    await _chromeChannel.invokeMethod<void>('setTitleStripHeight', height);
  } on MissingPluginException {
    // Running without the macOS runner (tests, other hosts).
  }
}

bool get _isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
bool get _isWindows =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

bool get _drawsCaptionButtons =>
    _isWindows || (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux);

/// True on desktop builds, where the native title bar is hidden and the app
/// owns that space.
bool get hasCustomWindowChrome => _isMacOS || _drawsCaptionButtons;

/// Lets the user drag the window by [child], and double-click it to zoom, on
/// desktop. Elsewhere it is transparent.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!hasCustomWindowChrome) {
      return child;
    }
    return DragToMoveArea(child: child);
  }
}

/// The editor's header: controls and the map card centered on one band,
/// with the traffic lights (macOS) or caption buttons (Windows, Linux) on
/// that same line. On macOS the window is told the band's height so the
/// lights move down to meet it, and back up when the editor closes. Windows
/// and Linux split the canvas gap evenly above and below the band.
class EditorWindowHeader extends StatefulWidget {
  const EditorWindowHeader({super.key, required this.child});

  final Widget child;

  @override
  State<EditorWindowHeader> createState() => _EditorWindowHeaderState();
}

class _EditorWindowHeaderState extends State<EditorWindowHeader> {
  @override
  void initState() {
    super.initState();
    _editorHeadersMounted++;
    _syncMacTitleStripHeight();
  }

  @override
  void dispose() {
    // The skeleton and the real header swap within one frame, so count
    // mounts instead of assuming this was the last one.
    _editorHeadersMounted--;
    _syncMacTitleStripHeight();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WindowDragArea(
      child: Padding(
        padding: _drawsCaptionButtons
            ? const EdgeInsets.symmetric(vertical: 5)
            : const EdgeInsets.only(bottom: 10),
        child: SizedBox(
          height: kEditorHeaderHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const MacTrafficLightInset(),
              Expanded(child: widget.child),
              const WindowCaptionButtons(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The compact Icarus lockup at the start of the Windows library strip.
class WindowsIcarusWordmark extends StatelessWidget {
  const WindowsIcarusWordmark({super.key});

  @override
  Widget build(BuildContext context) {
    if (!_isWindows) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(left: 10, right: 4),
      child: SvgPicture.asset(
        'assets/brand/icarus-wordmark.svg',
        height: 14,
        semanticsLabel: 'Icarus',
      ),
    );
  }
}

/// Blank space where the macOS traffic lights sit. Collapses in full screen,
/// where macOS hides them, and on every other platform.
class MacTrafficLightInset extends StatefulWidget {
  const MacTrafficLightInset({super.key});

  @override
  State<MacTrafficLightInset> createState() => _MacTrafficLightInsetState();
}

class _MacTrafficLightInsetState extends State<MacTrafficLightInset>
    with WindowListener {
  bool _fullScreen = false;

  @override
  void initState() {
    super.initState();
    if (!_isMacOS) return;
    windowManager.addListener(this);
    windowManager.isFullScreen().then((value) {
      if (mounted && value != _fullScreen) {
        setState(() => _fullScreen = value);
      }
    });
  }

  @override
  void dispose() {
    if (_isMacOS) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() => setState(() => _fullScreen = true);

  @override
  void onWindowLeaveFullScreen() => setState(() => _fullScreen = false);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        width: _isMacOS && !_fullScreen ? kMacTrafficLightInset : 0);
  }
}

/// Minimize, maximize, and close for platforms whose native buttons went
/// away with the title bar. Empty on macOS and web.
class WindowCaptionButtons extends StatefulWidget {
  const WindowCaptionButtons({super.key});

  @override
  State<WindowCaptionButtons> createState() => _WindowCaptionButtonsState();
}

class _WindowCaptionButtonsState extends State<WindowCaptionButtons>
    with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (!_drawsCaptionButtons) return;
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted && value != _maximized) {
        setState(() => _maximized = value);
      }
    });
  }

  @override
  void dispose() {
    if (_drawsCaptionButtons) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    if (!_drawsCaptionButtons) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        WindowCaptionButton.minimize(
          brightness: Brightness.dark,
          onPressed: windowManager.minimize,
        ),
        if (_maximized)
          WindowCaptionButton.unmaximize(
            brightness: Brightness.dark,
            onPressed: windowManager.unmaximize,
          )
        else
          WindowCaptionButton.maximize(
            brightness: Brightness.dark,
            onPressed: windowManager.maximize,
          ),
        // Goes through window_manager so the editor's unsaved-changes guard
        // (setPreventClose) still runs.
        WindowCaptionButton.close(
          brightness: Brightness.dark,
          onPressed: windowManager.close,
        ),
      ],
    );
  }
}

/// The frame that stands in for the native title bar. The screen places a
/// [WindowDragArea] only in its empty space so controls receive taps without
/// waiting for the title bar's double-click gesture.
class AppWindowStrip extends StatelessWidget {
  const AppWindowStrip({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('app-window-strip'),
      height: kWindowStripHeight,
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        border: Border(
          bottom: BorderSide(color: Settings.tacticalVioletTheme.border),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MacTrafficLightInset(),
          Expanded(child: child),
          const WindowCaptionButtons(),
        ],
      ),
    );
  }
}
