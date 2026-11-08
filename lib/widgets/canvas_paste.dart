import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/canvas_clipboard_provider.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/clipboard_service.dart';
import 'package:icarus/widgets/canvas_selection_layer.dart';
import 'package:icarus/widgets/platform_feature_toast.dart';
import 'package:toastification/toastification.dart';

/// The editor's paste shortcut, for anywhere in [child]: it can't fire from a
/// dialog, a menu or the library, and it leaves a text field's paste alone.
///
/// What was copied last is what pastes. Copying items on the canvas empties
/// the system clipboard, so a picture found there was copied after them and
/// goes first. With no picture there, the copied items do.
class CanvasPaste extends ConsumerStatefulWidget {
  const CanvasPaste({
    required this.child,
    this.readPicture = ClipboardService.readPastedImage,
    super.key,
  });

  final Widget child;
  final Future<ClipboardImage?> Function() readPicture;

  @override
  ConsumerState<CanvasPaste> createState() => _CanvasPasteState();
}

class _CanvasPasteState extends ConsumerState<CanvasPaste> {
  late final _action = _PasteAction(isEnabled: _canPaste, paste: _paste);
  bool _pasting = false;

  bool _canPaste() =>
      !isTypingInTextField() &&
      !ref.read(writingCaptionProvider) &&
      ref.read(currentStrategyCapabilitiesProvider).canEditPages &&
      !ref.read(interactionStateProvider).isLineUpMode &&
      !ref.read(transitionProvider).active;

  Future<void> _paste() async {
    if (_pasting) return;
    _pasting = true;
    try {
      // Reading can take a moment: the paste belongs to the page it was
      // pressed on, or to none.
      final strategyId = ref.read(strategyProvider).strategyId;
      final pageId = ref.read(strategyPageSessionProvider).activePageId;
      bool stillThere() =>
          ref.read(strategyProvider).strategyId == strategyId &&
          ref.read(strategyPageSessionProvider).activePageId == pageId &&
          _canPaste();

      final picture = await widget.readPicture();
      if (!mounted) return;
      if (picture != null) {
        await _placePicture(picture, stillThere);
      } else if (ref.read(canvasClipboardProvider) == null) {
        _refuse('No image found in clipboard');
      } else if (!stillThere()) {
        _refuse(_pageChanged);
      } else if (ref.read(interactionStateProvider).itemsInReach) {
        await _pasteItems();
      }
    } on ClipboardBusyException {
      if (mounted) _refuse(ClipboardService.busyMessage);
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Paste failed: $error',
        error: error,
        stackTrace: stackTrace,
        source: 'canvas_paste.paste',
        promptUser: false,
      );
      if (mounted) _refuse("Couldn't paste what you copied.");
    } finally {
      _pasting = false;
    }
  }

  /// Puts the picture in the middle of the screen. A drawing tool in hand
  /// goes down first, as it does for the Add Image button.
  Future<void> _placePicture(
    ClipboardImage picture,
    bool Function() stillThere,
  ) async {
    if (!ensureFeatureAvailable(ref, PlatformFeature.addImages)) return;
    // The map shows nothing until the picture is ready, half a second for
    // a 1080p Windows screenshot and a few at 4K: see pngOfBitmap.
    ToastificationItem? notice;
    final slow = Timer(_slowPicture, () {
      notice = Settings.showToast(
        message: 'Adding picture…',
        backgroundColor: Settings.tacticalVioletTheme.secondary,
        // Past pngOfBitmap's limit, so no notice outlasts what it describes.
        autoCloseDuration: const Duration(seconds: 20),
      );
    });
    try {
      final bytes = await picture.saved;
      if (!mounted) return;
      if (!stillThere()) {
        _refuse(_pageChanged);
        return;
      }
      ref
          .read(interactionStateProvider.notifier)
          .update(InteractionState.navigation);
      final added =
          await ref.read(placedImageProvider.notifier).addImageOnScreen(bytes);
      if (!added && mounted) _refuse('Clipboard image type not supported');
    } finally {
      slow.cancel();
      if (notice case final item?) _dismissAfterItShows(item);
    }
  }

  /// A toast joins the screen on the next frame, and dismissing it before
  /// then does nothing: it would show afterwards and stay.
  void _dismissAfterItShows(ToastificationItem toast) {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => toastification.dismiss(toast))
      ..ensureVisualUpdate();
  }

  Future<void> _pasteItems() async {
    final refusal = await ref.read(canvasClipboardProvider.notifier).paste();
    if (refusal == null || !mounted) return;
    final copiedOn = ref.read(canvasClipboardProvider)?.map;
    _refuse(
      switch (refusal) {
        PasteRefusal.otherMap => copiedOn == null
            ? 'What you copied is from another map.'
            : 'What you copied is from ${Maps.displayName(copiedOn)}. Paste '
                'it into a strategy on ${Maps.displayName(copiedOn)}.',
        PasteRefusal.picturesMissing =>
          "A picture in what you copied couldn't be read when you copied "
              'it, so nothing was pasted. Check your connection and copy '
              'it again.',
        PasteRefusal.pageChanged => _pageChanged,
        PasteRefusal.pictureTooLarge =>
          'A picture in what you copied is over 15 MB, more than a cloud '
              'strategy takes, so nothing was pasted.',
      },
    );
  }

  static const _slowPicture = Duration(milliseconds: 200);

  static const _pageChanged =
      'The page changed before the paste finished, so nothing was pasted.';

  void _refuse(String message) => Settings.showToast(
        message: message,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );

  @override
  Widget build(BuildContext context) => Actions(
        actions: {PasteImageIntent: _action},
        child: widget.child,
      );
}

class _PasteAction extends Action<PasteImageIntent> {
  _PasteAction({required bool Function() isEnabled, required this.paste})
      : _isEnabled = isEnabled;

  final bool Function() _isEnabled;
  final Future<void> Function() paste;

  @override
  bool isEnabled(PasteImageIntent intent) => _isEnabled();

  // A browser only sends its paste event for a key press left unhandled.
  @override
  bool consumesKey(PasteImageIntent intent) => !kIsWeb;

  @override
  Object? invoke(PasteImageIntent intent) {
    unawaited(paste());
    return null;
  }
}
