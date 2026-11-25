import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/widgets/context_menu_region.dart';
import 'package:icarus/widgets/strategy_look.dart';
import 'package:icarus/widgets/strategy_view_skeleton.dart';

const editorBusyAfter = Duration(milliseconds: 500);

class EditorInputGate extends ConsumerStatefulWidget {
  const EditorInputGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<EditorInputGate> createState() => _EditorInputGateState();
}

class _EditorInputGateState extends ConsumerState<EditorInputGate> {
  final _focus = FocusNode(
    debugLabel: 'editor-input-gate',
    canRequestFocus: false,
    skipTraversal: true,
  );
  late final ProviderSubscription<StrategyOpening?> _opening;

  bool get _closed => ref.read(strategyOpeningProvider) != null;

  @override
  void initState() {
    super.initState();
    _opening = ref.listenManual(strategyOpeningProvider, (before, now) {
      _close(now != null);
      if (before != null || now == null) return;
      ref.read(captionCardProvider.notifier).closeNow();
      ref.read(deleteMenuProvider.notifier).requestClose();
      ContextMenuRegion.closeOpen();
    });
    _close(_closed);
  }

  void _close(bool closed) {
    _focus.descendantsAreFocusable = !closed;
    FocusManager.instance.removeListener(_sendFocusOut);
    if (closed) {
      FocusManager.instance.addListener(_sendFocusOut);
      _sendFocusOut();
    }
  }

  void _sendFocusOut() {
    final held = FocusManager.instance.primaryFocus;
    if (held != null && held != _focus && held.ancestors.contains(_focus)) {
      held.unfocus();
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_sendFocusOut);
    _opening.close();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opening = ref.watch(strategyOpeningProvider) != null;
    return _ClosedWhile(
      closed: () => _closed,
      child: AbsorbPointer(
        absorbing: opening,
        child: Focus.withExternalFocusNode(
          focusNode: _focus,
          child: widget.child,
        ),
      ),
    );
  }
}

class _ClosedWhile extends SingleChildRenderObjectWidget {
  const _ClosedWhile({required this.closed, required super.child});

  final bool Function() closed;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderClosedWhile(closed);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderClosedWhile renderObject,
  ) =>
      renderObject.closed = closed;
}

class _RenderClosedWhile extends RenderProxyBox {
  _RenderClosedWhile(this.closed);

  bool Function() closed;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => closed()
      ? size.contains(position)
      : super.hitTest(result, position: position);
}

class EditorOpeningSkeleton extends ConsumerStatefulWidget {
  const EditorOpeningSkeleton({super.key, required this.leading});

  final Widget leading;

  @override
  ConsumerState<EditorOpeningSkeleton> createState() =>
      _EditorOpeningSkeletonState();
}

class _EditorOpeningSkeletonState extends ConsumerState<EditorOpeningSkeleton> {
  Timer? _wait;
  var _visible = false;
  var _drawn = false;
  StrategyLook _look = unknownStrategyLook;

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  StrategyLook _lookOf(StrategyOpening opening) =>
      strategyLookFor(ref, opening.strategyId, opening.source);

  void _follow(StrategyOpening? before, StrategyOpening? now) {
    if (now == null) {
      _wait?.cancel();
      if (_visible) {
        setState(() => _visible = false);
      } else if (_drawn) {
        setState(() => _drawn = false);
      }
      return;
    }
    if (before != null) {
      if (_drawn) setState(() => _look = _lookOf(now));
      return;
    }
    _wait?.cancel();
    _wait = Timer(editorBusyAfter, () {
      final opening = ref.read(strategyOpeningProvider);
      if (!mounted || opening == null) return;
      setState(() {
        _look = _lookOf(opening);
        _drawn = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _drawn) {
          setState(() => _visible = ref.read(strategyOpeningProvider) != null);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<StrategyOpening?>(strategyOpeningProvider, _follow);
    final look = _look;
    if (!_drawn) return const SizedBox.shrink();
    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        curve: _visible ? Settings.easeOut : Settings.easeOut.flipped,
        onEnd: () {
          if (mounted && !_visible) setState(() => _drawn = false);
        },
        child: StrategyViewSkeleton(
          strategyName: look.name,
          mapValue: look.map,
          isAttack: look.isAttack,
          leading: widget.leading,
        ),
      ),
    );
  }
}
