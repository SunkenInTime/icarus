import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:icarus/strategy_view.dart';
import 'package:window_manager/window_manager.dart';

class WindowCloseGuard extends ConsumerStatefulWidget {
  const WindowCloseGuard({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WindowCloseGuard> createState() => _WindowCloseGuardState();
}

enum _Closing { no, asking, sent }

class _WindowCloseGuardState extends ConsumerState<WindowCloseGuard>
    with WindowListener {
  var _closing = _Closing.no;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (!kIsWeb) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() => unawaited(_close());

  Future<void> _close() async {
    if (_closing != _Closing.no) return;
    _closing = _Closing.asking;
    try {
      final strategies = ref.read(strategyProvider.notifier);
      while (StrategyView.isOnScreen && mounted) {
        final navigator = appNavigatorKey.currentState;
        if (navigator == null) return;
        final answer = await guardUnsavedStrategyExit(
          context: navigator.context,
          ref: ref,
          source: 'WindowCloseGuard',
        );
        if (answer is! Leave || !mounted) return;
        if (answer.seen.isNow(strategies.askedByTheUserNow())) {
          strategies.cancelPendingSave();
          _closing = _Closing.sent;
          unawaited(windowManager.setPreventClose(false));
          unawaited(windowManager.close());
          return;
        }
      }
    } finally {
      if (_closing == _Closing.asking) _closing = _Closing.no;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
