import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/desktop_update_provider.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/welcome_tour_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/welcome_tour/welcome_tour_pictures.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Everything the welcome tour says. `**word**` marks a word drawn in the
/// foreground color, the name of something the user will see on screen.
abstract final class WelcomeTourCopy {
  static const kicker = 'New in this update';

  static const libraryTitle = 'Your library is still here';
  static const libraryBody =
      'Everything you made before this update is saved on this computer, '
      'exactly as it was. Nothing moves unless you move it.';

  static const cloudTitle = 'Sign in to sync and share';
  static const cloudBody =
      'Strategies you make while signed in are saved to your account, so '
      'they open on any computer and you can share them with your team. To '
      'bring an older one along, right-click it and choose **Move to cloud**.';

  // What the release promises about replays. Icarus reads replays only up
  // to VALORANT patch 13.06 for now, so this is the copy most likely to
  // change before the release ships.
  static const replaysTitle = 'Turn your matches into strategies';
  static const replaysBody =
      'The **Replays** tab lists matches you downloaded in VALORANT. Pause on '
      'any moment and press **Capture** to save it as a strategy page.';
}

/// Shows the welcome tour once per install, the first time the library is
/// on screen. Desktop only: the web beta has no local library to reassure
/// about and no replays. It waits its turn: a launch that opens a file or a
/// link, an update waiting to install, or anything already open over the
/// library puts it off until the next launch.
Future<void> showWelcomeTourAtLaunch(BuildContext context) async {
  // The container outlives the library screen, which may go away while the
  // update check is answering.
  final container = ProviderScope.containerOf(context, listen: false);
  if (container.read(welcomeTourLaunchCheckedProvider)) return;
  container.read(welcomeTourLaunchCheckedProvider.notifier).state = true;

  if (container.read(platformPolicyProvider).isWebBeta) return;
  if (container.read(appPreferencesProvider).welcomeTourSeen) return;
  if (container.read(launchOpensFileOrLinkProvider)) return;
  if (await _updateMayPrompt(container)) return;

  // Let anything the launch opened reach the screen before looking.
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return;
  if (ModalRoute.of(context)?.isCurrent != true) return;

  // Seen once it is on screen, however it is closed.
  unawaited(
    container.read(appPreferencesProvider.notifier).markWelcomeTourSeen(),
  );
  await WelcomeTourDialog.show(context);
}

/// Whether the update check found an update, whose dialog then owns the
/// screen, or has not answered in time to know. Either way the tour waits.
Future<bool> _updateMayPrompt(ProviderContainer container) async {
  try {
    return await () async {
      final status = await container.read(appUpdateStatusProvider.future);
      if (status.isUpdateAvailable) return true;
      final desktopUpdate = container.read(desktopUpdateControllerProvider);
      if (desktopUpdate == null) return false;
      await desktopUpdate.firstCheck;
      return desktopUpdate.needUpdate;
    }()
        .timeout(const Duration(seconds: 10));
  } on TimeoutException {
    return true;
  } catch (_) {
    // A failed check shows no update dialog, so nothing competes.
    return false;
  }
}

enum _Step { library, cloud, replays }

/// One card, one step at a time: what stayed the same, what accounts add,
/// and what replays are for. Each step can be acted on from the card.
class WelcomeTourDialog extends ConsumerStatefulWidget {
  const WelcomeTourDialog({super.key, required this.showLibraryStep});

  static const double _width = 480;
  static const double _padding = 24;

  /// The first step promises that existing work is still here, so a library
  /// with nothing in it skips that step.
  final bool showLibraryStep;

  static Future<void> show(BuildContext context) {
    final hasLocalWork =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).isNotEmpty ||
            Hive.box<Folder>(HiveBoxNames.foldersBox).isNotEmpty;
    return showShadDialog<void>(
      context: context,
      builder: (context) => WelcomeTourDialog(showLibraryStep: hasLocalWork),
    );
  }

  @override
  ConsumerState<WelcomeTourDialog> createState() => _WelcomeTourDialogState();
}

class _WelcomeTourDialogState extends ConsumerState<WelcomeTourDialog> {
  late final List<_Step> _steps = [
    if (widget.showLibraryStep) _Step.library,
    _Step.cloud,
    _Step.replays,
  ];
  int _index = 0;

  void _goTo(int index) => setState(() => _index = index);

  void _next() => _goTo(_index + 1);

  Future<void> _signIn() async {
    final signedIn = await showDialog<bool>(
      context: context,
      builder: (_) => const AuthDialog(),
    );
    if (signedIn == true && mounted) _next();
  }

  void _openReplays() {
    Navigator.of(context).pop();
    ref.read(libraryNavigationProvider).showReplays();
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(authProvider.select((a) => a.isAuthenticated));
    final step = _steps[_index];
    return ShadDialog(
      key: const ValueKey('welcome-tour'),
      constraints: const BoxConstraints(maxWidth: WelcomeTourDialog._width),
      padding: const EdgeInsets.all(WelcomeTourDialog._padding),
      child: SizedBox(
        width: WelcomeTourDialog._width - WelcomeTourDialog._padding * 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Every step is laid out so the card keeps the tallest one's
            // height and the buttons never jump.
            IndexedStack(
              index: _index,
              children: [for (final step in _steps) _StepPage(step: step)],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                _StepDots(count: _steps.length, current: _index, onTap: _goTo),
                const Spacer(),
                if (_index > 0) ...[
                  ShadButton.ghost(
                    foregroundColor:
                        Settings.tacticalVioletTheme.mutedForeground,
                    hoverForegroundColor:
                        Settings.tacticalVioletTheme.foreground,
                    onPressed: () => _goTo(_index - 1),
                    child: const Text('Back'),
                  ),
                  const SizedBox(width: 8),
                ],
                ..._actions(step, signedIn: signedIn),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(_Step step, {required bool signedIn}) {
    Widget secondary(String label, VoidCallback onPressed) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ShadButton.secondary(
            onPressed: onPressed,
            child: Text(label),
          ),
        );
    Widget primary(String label, VoidCallback onPressed) => ShadButton(
          onPressed: onPressed,
          child: Text(label),
        );

    return switch (step) {
      _Step.library => [primary('Next', _next)],
      _Step.cloud when signedIn => [primary('Next', _next)],
      _Step.cloud => [
          secondary('Not now', _next),
          primary('Sign in', _signIn),
        ],
      _Step.replays => [
          secondary('Done', () => Navigator.of(context).pop()),
          primary('Open Replays', _openReplays),
        ],
    };
  }
}

class _StepPage extends StatelessWidget {
  const _StepPage({required this.step});

  final _Step step;

  @override
  Widget build(BuildContext context) {
    final (picture, title, body) = switch (step) {
      _Step.library => (
          const WelcomeLibraryPicture(),
          WelcomeTourCopy.libraryTitle,
          WelcomeTourCopy.libraryBody,
        ),
      _Step.cloud => (
          const WelcomeCloudPicture(),
          WelcomeTourCopy.cloudTitle,
          WelcomeTourCopy.cloudBody,
        ),
      _Step.replays => (
          const WelcomeReplayPicture(),
          WelcomeTourCopy.replaysTitle,
          WelcomeTourCopy.replaysBody,
        ),
    };
    const theme = Settings.tacticalVioletTheme;
    final bodyStyle = TextStyle(
      fontSize: 14,
      height: 1.45,
      color: theme.mutedForeground,
    );
    final named = TextStyle(
      fontWeight: FontWeight.w500,
      color: theme.foreground,
    );
    final parts = body.split('**');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        picture,
        const SizedBox(height: 18),
        Text(
          WelcomeTourCopy.kicker,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: theme.mutedForeground,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: theme.foreground,
          ),
        ),
        const SizedBox(height: 6),
        Text.rich(
          TextSpan(
            style: bodyStyle,
            children: [
              for (var i = 0; i < parts.length; i++)
                TextSpan(text: parts[i], style: i.isOdd ? named : null),
            ],
          ),
        ),
      ],
    );
  }
}

/// Where the user is in the tour. The current step is the selection, so it
/// alone is violet; any dot jumps to its step.
class _StepDots extends StatelessWidget {
  const _StepDots({
    required this.count,
    required this.current,
    required this.onTap,
  });

  final int count;
  final int current;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          Semantics(
            button: true,
            selected: i == current,
            label: 'Step ${i + 1} of $count',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTap(i),
                // The padding widens the target past the 6px dot.
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 8,
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    width: i == current ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == current ? theme.primary : theme.input,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
