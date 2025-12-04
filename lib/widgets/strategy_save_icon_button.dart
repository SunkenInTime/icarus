import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auto_save_notifier.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The save button that animates on auto-save pings.
class AutoSaveButton extends ConsumerStatefulWidget {
  const AutoSaveButton({super.key});

  @override
  ConsumerState<AutoSaveButton> createState() => _AutoSaveButtonState();
}

class _AutoSaveButtonState extends ConsumerState<AutoSaveButton>
    with SingleTickerProviderStateMixin {
  /// Listen to the autoSave ping counter.
  // late final AutoDisposeProviderSubscription<int> _sub;

  /// Drives continuous rotation in the loading phase.
  late final AnimationController _rotationController;

  /// Our own internal phase.
  _Phase _phase = _Phase.idle;

  @override
  void initState() {
    super.initState();
    _lastPing = ref.read(autoSaveProvider);
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(); // we'll stop when not loading
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  void _startAutoSaveAnimation() {
    if (!mounted) return;

    setState(() => _phase = _Phase.loading);
    _rotationController.repeat();

    // After 3s, show check and snackbar
    Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _rotationController.stop();
      setState(() => _phase = _Phase.success);

      final sonner = ShadSonner.of(context);
      final id = Random().nextInt(1000);
      sonner.show(
        ShadToast(
          backgroundColor: Colors.greenAccent,
          id: id,
          title: const Text('Auto-Save Complete'),
        ),
      );

      // // show the snack bar here, outside build
      // ScaffoldMessenger.of(context).showSnackBar(
      //   const SnackBar(
      //     content: Center(
      //       child: Text(
      //         "Auto‐save complete",
      //         style: TextStyle(color: Colors.white),
      //       ),
      //     ),
      //     duration: Duration(seconds: 2),
      //     backgroundColor: Settings.sideBarColor,
      //     behavior: SnackBarBehavior.floating,
      //     width: 200,
      //   ),
      // );

      // after 1s go back to idle
      Timer(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() => _phase = _Phase.idle);
      });
    });
  }

  int _lastPing = 0;
  @override
  Widget build(BuildContext context) {
    final ping = ref.watch(autoSaveProvider);

    if (ping != _lastPing) {
      _lastPing = ping;
      _startAutoSaveAnimation();
    }
    Widget icon;
    switch (_phase) {
      case _Phase.idle:
        _rotationController.stop();
        icon = const Icon(Icons.save);
        break;

      case _Phase.loading:
        _rotationController.repeat();
        icon = RotationTransition(
          turns: _rotationController,
          child: const Icon(Icons.refresh),
        );
        break;

      case _Phase.success:
        _rotationController.stop();
        icon = const Icon(Icons.check, color: Colors.greenAccent);

        break;
    }

    return IconButton(
      icon: icon,
      onPressed: () async {
        // manual save path shows a SnackBar
        await ref
            .read(strategyProvider.notifier)
            .forceSaveNow(ref.read(strategyProvider).id);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Center(
              child: Text(
                "File Saved",
                style: TextStyle(color: Colors.white),
              ),
            ),
            duration: Duration(seconds: 2),
            backgroundColor: Settings.sideBarColor,
            behavior: SnackBarBehavior.floating,
            width: 200,
          ),
        );
      },
    );
  }
}

enum _Phase { idle, loading, success }
