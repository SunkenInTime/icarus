import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auto_save_notifier.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

/// Saves the open strategy immediately and tells the user what landed.
Future<void> saveStrategyNow(BuildContext context, WidgetRef ref) async {
  final strategyId = ref.read(strategyProvider).strategyId;
  if (strategyId == null) return;
  await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
  if (!context.mounted) return;

  final latestSaveState = ref.read(strategySaveStateProvider);
  final hasIncompleteMediaSync = latestSaveState.hasPendingMediaSync ||
      latestSaveState.mediaSyncErrorCount > 0;
  final toastMessage = hasIncompleteMediaSync
      ? latestSaveState.mediaSyncErrorCount > 0
          ? 'Saved on this device. Media sync needs retry.'
          : 'Saved on this device. Media still syncing.'
      : 'Saved';

  toastification.showCustom(
    context: context,
    autoCloseDuration: const Duration(seconds: 3),
    alignment: Alignment.bottomCenter,
    builder: (context, holder) {
      return Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Settings.tacticalVioletTheme.border),
        ),
        child: Text(
          toastMessage,
          style: ShadTheme.of(context)
              .textTheme
              .small
              .copyWith(color: Settings.tacticalVioletTheme.foreground),
        ),
      );
    },
  );
}

/// The save button of a local strategy. Shows a spinner while an auto-save
/// runs and a check when it lands, then rests on the save glyph.
class AutoSaveButton extends ConsumerStatefulWidget {
  const AutoSaveButton({
    super.key,
    this.style = kEditorToolbarButtonStyle,
  });

  final EditorToolbarButtonStyle style;

  @override
  ConsumerState<AutoSaveButton> createState() => _AutoSaveButtonState();
}

class _AutoSaveButtonState extends ConsumerState<AutoSaveButton> {
  _Phase _phase = _Phase.idle;
  Timer? _successTimer;
  Timer? _idleTimer;
  int _lastPing = 0;

  @override
  void initState() {
    super.initState();
    _lastPing = ref.read(autoSaveProvider);
  }

  @override
  void dispose() {
    _successTimer?.cancel();
    _idleTimer?.cancel();
    super.dispose();
  }

  void _startAutoSaveAnimation() {
    if (!mounted) return;
    _successTimer?.cancel();
    _idleTimer?.cancel();
    setState(() => _phase = _Phase.loading);
    _successTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _phase = _Phase.success);
      _idleTimer = Timer(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() => _phase = _Phase.idle);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final ping = ref.watch(autoSaveProvider);
    final canEditPages = ref.watch(
      currentStrategyCapabilitiesProvider.select(
        (capabilities) => capabilities.canEditPages,
      ),
    );

    if (ping != _lastPing) {
      _lastPing = ping;
      _startAutoSaveAnimation();
    }

    final size = widget.style.iconSize;
    final Widget icon = switch (_phase) {
      _Phase.idle => Icon(LucideIcons.save300, key: const ValueKey('idle')),
      _Phase.loading => SizedBox(
          key: const ValueKey('loading'),
          width: size - 2,
          height: size - 2,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            valueColor: AlwaysStoppedAnimation<Color>(
              Settings.tacticalVioletTheme.mutedForeground,
            ),
          ),
        ),
      _Phase.success => Icon(
          LucideIcons.check300,
          key: const ValueKey('success'),
          color: Settings.allyBGColor,
        ),
    };

    return EditorToolbarButton(
      key: const ValueKey('local-save-button'),
      style: widget.style,
      tooltip: canEditPages ? 'Save' : 'View only',
      enabled: canEditPages,
      onPressed: () => saveStrategyNow(context, ref),
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        child: icon,
      ),
    );
  }
}

enum _Phase { idle, loading, success }
