import 'dart:async';

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

class EditorInputGate extends ConsumerWidget {
  const EditorInputGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(strategyOpeningProvider, (before, now) {
      if (before != null || now == null) return;
      ref.read(captionCardProvider.notifier).closeNow();
      ref.read(deleteMenuProvider.notifier).requestClose();
      ContextMenuRegion.closeOpen();
    });
    final opening = ref.watch(
      strategyOpeningProvider.select((opening) => opening != null),
    );
    return AbsorbPointer(
      absorbing: opening,
      child: ExcludeFocus(excluding: opening, child: child),
    );
  }
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

  void _follow(String? opening) {
    _wait?.cancel();
    if (opening == null) {
      if (_visible) {
        setState(() => _visible = false);
      } else if (_drawn) {
        setState(() => _drawn = false);
      }
      return;
    }
    _wait = Timer(editorBusyAfter, () {
      if (!mounted) return;
      final source = ref.read(strategyOpeningProvider.notifier).source;
      setState(() {
        _look = source == null
            ? unknownStrategyLook
            : strategyLookFor(ref, opening, source);
        _drawn = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _drawn && _wait?.isActive == false) {
          setState(() => _visible = ref.read(strategyOpeningProvider) != null);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(strategyOpeningProvider, (_, now) => _follow(now));
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
