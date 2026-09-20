import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/routes.dart';
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
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:icarus/widgets/window_chrome.dart';
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
      settings: const RouteSettings(name: Routes.strategyView),
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
          // The same 40px strip as the library, so the traffic lights never
          // move: Library and the wordmark on the left, the strategy in the
          // middle, Discord on the right. The map card lives on the canvas
          // with the toolbar.
          AppWindowStrip(
            child: Stack(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 6),
                    ShadTooltip(
                      builder: (context) => const Text('Library'),
                      child: ShadIconButton.ghost(
                        width: 28,
                        height: 28,
                        foregroundColor:
                            Settings.tacticalVioletTheme.mutedForeground,
                        hoverForegroundColor:
                            Settings.tacticalVioletTheme.foreground,
                        onPressed: _leaveToLibrary,
                        icon: const Icon(LucideIcons.house300, size: 18),
                      ),
                    ),
                    const IcarusWordmark(),
                    if (kIsWeb)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8.0),
                        child: DemoTag(),
                      ),
                    const Expanded(
                      child: WindowDragArea(child: SizedBox.expand()),
                    ),
                    const _DiscordLink(),
                    const SizedBox(width: 10),
                  ],
                ),
                const Center(child: StrategyQuickSwitcher()),
              ],
            ),
          ),
          // The canvas runs right up to the strip; each floating panel keeps
          // its own 8px of air so no bare band shows between the two.
          const Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: DeleteCapture()),
                Align(
                  alignment: Alignment.centerLeft,
                  child: RepaintBoundary(child: InteractiveMap()),
                ),
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MapSelector(),
                        SizedBox(height: 8),
                        EditorToolbar(),
                      ],
                    ),
                  ),
                ),
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

/// The bug-report link at the end of the editor strip: text when there is
/// room, the glyph alone when there isn't.
class _DiscordLink extends StatelessWidget {
  const _DiscordLink();

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final showLabel = MediaQuery.sizeOf(context).width >= 1000;
    final button = ShadButton.ghost(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      foregroundColor: theme.mutedForeground,
      hoverForegroundColor: theme.foreground,
      onPressed: () async {
        await launchUrl(Settings.dicordLink);
      },
      leading: showLabel ? null : const Icon(CustomIcons.discord, size: 16),
      child: showLabel
          ? const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Have any bugs? Join the Discord',
                  style: TextStyle(fontSize: 13),
                ),
                SizedBox(width: 8),
                Icon(CustomIcons.discord, size: 16),
              ],
            )
          : const SizedBox.shrink(),
    );
    if (showLabel) return button;
    return ShadTooltip(
      builder: (context) => const Text('Have any bugs? Join the Discord'),
      child: button,
    );
  }
}
