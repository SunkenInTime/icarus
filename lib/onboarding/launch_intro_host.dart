import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/onboarding/sunrise.dart';
import 'package:icarus/onboarding/ignite_splash.dart';
import 'package:icarus/onboarding/launch_intro.dart';
import 'package:icarus/onboarding/wordmark_glyphs.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/widgets/asset_svg.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';

class LaunchIntroHost extends ConsumerStatefulWidget {
  const LaunchIntroHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LaunchIntroHost> createState() => _LaunchIntroHostState();
}

class _LaunchIntroHostState extends ConsumerState<LaunchIntroHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _presence,
    curve: Settings.easeOut,
    reverseCurve: Settings.easeOut.flipped,
  );

  @override
  void dispose() {
    _presence.dispose();
    super.dispose();
  }

  BuildContext? get _library => appNavigatorKey.currentState?.overlay?.context;

  void _finish() {
    ref.read(launchIntroProvider.notifier).state = null;
  }

  Future<void> _leave() async {
    await _presence.reverse();
    if (mounted) _finish();
  }

  Future<void> _begin() async {
    _finish();
    final library = _library;
    if (library == null || !library.mounted) return;
    await pickMapAndOpenNewStrategy(ref: ref, context: library);
  }

  Future<void> _logIn() async {
    _finish();
    final library = _library;
    if (library == null || !library.mounted) return;
    await showDialog<void>(
      context: library,
      builder: (_) => const AuthDialog(),
    );
  }

  Rect? _wordmarkIn(BuildContext? navigator) {
    final layer = context.findRenderObject();
    if (layer is! RenderBox || navigator == null) return null;
    RenderBox? home;
    void visit(Element element) {
      if (home != null) return;
      final widget = element.widget;
      if (widget is AssetSvg && widget.assetName == wordmarkAsset) {
        final box = element.findRenderObject();
        if (box is RenderBox && box.hasSize) home = box;
        return;
      }
      element.visitChildren(visit);
    }

    navigator.visitChildElements(visit);
    final found = home;
    if (found == null) return null;
    return MatrixUtils.transformRect(
      found.getTransformTo(layer),
      Offset.zero & found.size,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(launchIntroProvider, (_, next) {
      if (next != null) _presence.value = 1;
    });
    final run = ref.watch(launchIntroProvider);
    final logIn = ref.watch(librarySignInRequiredProvider) ? _logIn : null;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (run != null && run.intro != LaunchIntro.none)
          AnimatedBuilder(
            animation: _presence,
            builder: (context, child) => IgnorePointer(
              ignoring: _presence.status == AnimationStatus.reverse,
              child: child,
            ),
            child: FadeTransition(
              opacity: _opacity,
              child: Material(
                type: MaterialType.transparency,
                child: KeyedSubtree(
                  key: ValueKey((run.intro, run.take)),
                  child: switch (run.intro) {
                    LaunchIntro.onboarding => _FirstRun(
                        afterLoader: kIsWeb && run.take == 0,
                        findWordmark: _wordmarkIn,
                        onStart: _begin,
                        onSkip: _leave,
                        onLogIn: logIn,
                      ),
                    LaunchIntro.splash => IgniteSplash(
                        findHome: () =>
                            _wordmarkIn(appNavigatorKey.currentContext),
                        onDone: _finish,
                        afterLoader: kIsWeb && run.take == 0,
                      ),
                    LaunchIntro.none => const SizedBox.shrink(),
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FirstRun extends StatefulWidget {
  const _FirstRun({
    required this.afterLoader,
    required this.findWordmark,
    required this.onStart,
    required this.onSkip,
    required this.onLogIn,
  });

  final bool afterLoader;
  final Rect? Function(BuildContext? within) findWordmark;
  final VoidCallback onStart;
  final VoidCallback onSkip;
  final VoidCallback? onLogIn;

  @override
  State<_FirstRun> createState() => _FirstRunState();
}

class _FirstRunState extends State<_FirstRun> {
  final GlobalKey _sunrise = GlobalKey();
  bool _splashLeaving = false;
  bool _splashDone = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Sunrise(
          key: _sunrise,
          held: !_splashLeaving,
          wordmarkShown: _splashDone,
          onStart: widget.onStart,
          onSkip: widget.onSkip,
          onLogIn: widget.onLogIn,
        ),
        if (!_splashDone)
          IgniteSplash(
            findHome: () => widget.findWordmark(_sunrise.currentContext),
            afterLoader: widget.afterLoader,
            onLeaving: () => setState(() => _splashLeaving = true),
            onDone: () => setState(() => _splashDone = true),
          ),
      ],
    );
  }
}
