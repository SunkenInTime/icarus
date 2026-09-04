import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:window_manager/window_manager.dart';

/// Height of the strip the app draws in place of the native title bar.
/// `macos/Runner/MainFlutterWindow.swift` centers the traffic lights on it.
const double kWindowStripHeight = 40;

/// Room reserved on the left for the native macOS traffic lights.
const double kMacTrafficLightInset = 78;

bool get _isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

bool get _drawsCaptionButtons =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

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
    return SizedBox(width: _isMacOS && !_fullScreen ? kMacTrafficLightInset : 0);
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

/// The strip that stands in for the native title bar: traffic-light inset,
/// the screen's own controls, caption buttons, all draggable.
class AppWindowStrip extends StatelessWidget {
  const AppWindowStrip({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return WindowDragArea(
      child: Container(
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
      ),
    );
  }
}
