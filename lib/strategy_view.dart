import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/sidebar.dart';
import 'package:icarus/widgets/delete_capture.dart';
import 'package:icarus/widgets/demo_tag.dart';
import 'package:icarus/widgets/strategy_view_skeleton.dart';
import 'package:icarus/widgets/strategy_quick_switcher.dart';
import 'package:icarus/widgets/map_selector.dart';
import 'package:icarus/widgets/pages_bar.dart';
import 'package:icarus/widgets/save_and_load_button.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

class StrategyView extends ConsumerStatefulWidget {
  const StrategyView({
    super.key,
    this.initialStrategyId,
    this.initialStrategyName,
    this.initialMapValue,
    this.initialIsAttack = true,
  });

  final String? initialStrategyId;
  final String? initialStrategyName;
  final MapValue? initialMapValue;
  final bool initialIsAttack;

  static PageRoute<void> route({
    String? initialStrategyId,
    String? initialStrategyName,
    MapValue? initialMapValue,
    bool initialIsAttack = true,
  }) {
    return PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, _) => StrategyView(
        initialStrategyId: initialStrategyId,
        initialStrategyName: initialStrategyName,
        initialMapValue: initialMapValue,
        initialIsAttack: initialIsAttack,
      ),
      transitionsBuilder: (context, animation, _, child) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(
              begin: 0.9,
              end: 1.0,
            ).chain(CurveTween(curve: Curves.easeOut)).animate(animation),
            child: child,
          ),
        );
      },
    );
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _StrategyViewState();
}

class _StrategyViewState extends ConsumerState<StrategyView>
    with WindowListener {
  bool _isClosingWindow = false;
  bool _isInitialLoadPending = false;
  bool _hasInitialLoadCompleted = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialStrategyId != null) {
      _isInitialLoadPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_loadInitialStrategy());
      });
    }
    if (!kIsWeb) {
      windowManager.addListener(this);
      _enableWindowCloseGuard();
    }
  }

  @override
  void dispose() {
    if (!kIsWeb) {
      windowManager.removeListener(this);
      windowManager.setPreventClose(false);
    }
    super.dispose();
  }

  Future<void> _enableWindowCloseGuard() async {
    await windowManager.setPreventClose(true);
  }

  Future<void> _loadInitialStrategy() async {
    final strategyId = widget.initialStrategyId;
    if (strategyId == null) {
      if (mounted) {
        setState(() => _isInitialLoadPending = false);
      }
      return;
    }

    try {
      await ref.read(strategyProvider.notifier).loadFromHive(strategyId);
      final loadedStrategy = ref.read(strategyProvider);
      if (loadedStrategy.id != strategyId || loadedStrategy.stratName == null) {
        throw StateError('Strategy "$strategyId" was not found.');
      }
      _hasInitialLoadCompleted = true;
    } catch (error, stackTrace) {
      developer.log(
        'Error loading strategy: $error',
        name: 'strategy_view',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        Settings.showToast(
          message: 'Could not load strategy.',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        Navigator.maybePop(context);
      }
    } finally {
      if (mounted) {
        setState(() => _isInitialLoadPending = false);
      }
    }
  }

  Future<void> _leaveToLibrary() async {
    await guardUnsavedStrategyExit(
      context: context,
      ref: ref,
      source: 'StrategyView.leaveToLibrary',
      onContinue: () async {
        ref
            .read(interactionStateProvider.notifier)
            .update(InteractionState.navigation);
        ref
            .read(agentFilterProvider.notifier)
            .updateFilterState(FilterState.all);
        ref.read(deleteMenuProvider.notifier).requestClose();
        await ref.read(strategyProvider.notifier).clearCurrentStrategy();
        if (mounted) {
          Navigator.pop(context);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(lineUpProvider, (previous, next) {
      if (previous?.isSelectingPosition == true &&
          next.isSelectingPosition == false) {
        showDialog(
          context: context,
          builder: (context) => const CreateLineupDialog(),
        );
      }
    });
    final strategyState = ref.watch(strategyProvider);
    final initialStrategyId = widget.initialStrategyId;
    final showSkeleton = _isInitialLoadPending ||
        (!_hasInitialLoadCompleted &&
            initialStrategyId != null &&
            (strategyState.stratName == null ||
                strategyState.id != initialStrategyId));

    if (showSkeleton) {
      return Scaffold(
        body: StrategyViewSkeleton(
          strategyName: widget.initialStrategyName,
          mapValue: widget.initialMapValue,
          isAttack: widget.initialIsAttack,
        ),
      );
    }

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: 15,
              top: 15,
              bottom: 10,
              right: 15,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    ShadIconButton.ghost(
                      foregroundColor: Colors.white,
                      onPressed: _leaveToLibrary,
                      icon: const Icon(Icons.home),
                    ),
                    const SizedBox(width: 5),
                    const MapSelector(),
                    if (kIsWeb)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8.0),
                        child: DemoTag(),
                      ),
                  ],
                ),
                const StrategyQuickSwitcher(),
                Row(
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        enabledMouseCursor: SystemMouseCursors.click,
                      ),
                      onPressed: () async {
                        await launchUrl(Settings.dicordLink);
                      },
                      child: const Row(
                        children: [
                          Text("Have any bugs? Join the Discord"),
                          SizedBox(width: 10),
                          Icon(CustomIcons.discord, color: Colors.white),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: DeleteCapture()),
                Align(
                  alignment: Alignment.centerLeft,
                  child: RepaintBoundary(child: InteractiveMap()),
                ),
                Align(alignment: Alignment.topLeft, child: SaveAndLoadButton()),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: PagesBar(),
                  ),
                ),
                Align(alignment: Alignment.centerRight, child: SideBarUI()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void onWindowClose() async {
    if (kIsWeb) {
      return;
    }
    if (_isClosingWindow) {
      await windowManager.close();
      return;
    }

    await guardUnsavedStrategyExit(
      context: context,
      ref: ref,
      source: 'StrategyView.onWindowClose',
      onContinue: () async {
        _isClosingWindow = true;
        await windowManager.setPreventClose(false);
        await windowManager.close();
      },
    );
  }
}
