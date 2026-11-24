import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus/widgets/context_menu_region.dart';
import 'package:icarus/widgets/strategy_view_skeleton.dart';

const editorBusyAfter = Duration(milliseconds: 200);

class EditorInputGate extends ConsumerWidget {
  const EditorInputGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(strategyOpeningProvider, (before, now) {
      if (before != null || now == null) return;
      FocusManager.instance.primaryFocus?.unfocus();
      ref.read(captionCardProvider.notifier).closeNow();
      ref.read(deleteMenuProvider.notifier).requestClose();
      ContextMenuRegion.closeOpen();
    });
    return AbsorbPointer(
      absorbing: ref.watch(
        strategyOpeningProvider.select((opening) => opening != null),
      ),
      child: child,
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
  LocalStrategySummary? _summary;

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
      final library = ref.read(localLibraryViewProvider);
      setState(() {
        _summary = library.isOpen ? library.strategy(opening) : null;
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
    final summary = _summary;
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
          strategyName: summary?.name,
          mapValue: summary?.mapData,
          isAttack: summary?.opensOnAttack ?? true,
          leading: widget.leading,
        ),
      ),
    );
  }
}
