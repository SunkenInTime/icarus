import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/draggable_widgets/caption_menu.dart';

/// Which item's caption card is open, or null, for the pointer's journey from
/// an item to its card.
final captionCardProvider =
    NotifierProvider<CaptionCardNotifier, String?>(CaptionCardNotifier.new);

class CaptionCardNotifier extends Notifier<String?> {
  /// Long enough that crossing the map or grabbing an item shows nothing.
  static const openDelay = Duration(milliseconds: 300);

  /// Long enough to reach the card, or come back to the item.
  static const closeDelay = Duration(milliseconds: 150);

  Timer? _opening;
  Timer? _closing;
  String? _hovered;
  bool _onCard = false;

  /// The regions the pointer is in and the item each belongs to: a shape's
  /// whole area and its center marker report apart.
  final _regions = <Object, String>{};

  /// Pointers held down. Nothing opens under a held press: it's a drag, a
  /// marquee or a click on its way.
  final _pressed = <int>{};

  @override
  String? build() {
    ref.onDispose(_cancelTimers);
    return null;
  }

  void _cancelTimers() {
    _opening?.cancel();
    _closing?.cancel();
  }

  bool _holdsCaption(String id) =>
      ref.read(appPreferencesProvider).showCaptions &&
      (placedItemById(ref.container, id)?.caption?.isNotEmpty ?? false);

  /// The pointer entered [region] of the item [id].
  void itemEntered(String id, Object region) {
    _regions[region] = id;
    _hovered = id;
    if (id == state) {
      _closing?.cancel();
      return;
    }
    _opening?.cancel();
    if (_pressed.isNotEmpty || !_holdsCaption(id)) return;
    _opening = Timer(openDelay, () {
      if (_hovered != id || _pressed.isNotEmpty || !_holdsCaption(id)) return;
      _closing?.cancel();
      _onCard = false;
      state = id;
    });
  }

  /// The pointer left [region], or it went from under the pointer. Flutter
  /// reports no exit for a region that's removed, so its owner calls this
  /// when it goes.
  void itemExited(Object region) {
    final id = _regions.remove(region);
    if (id == null || _regions.containsValue(id) || _hovered != id) return;
    _hovered = null;
    _opening?.cancel();
    if (id == state) _closeSoon();
  }

  /// Opens the card of [id] at once: a tap has no pointer to wait on.
  void openNow(String id) {
    _cancelTimers();
    if (_holdsCaption(id)) state = id;
  }

  void cardEntered() {
    _onCard = true;
    _closing?.cancel();
  }

  void cardExited() {
    _onCard = false;
    if (_hovered != state) _closeSoon();
  }

  void _closeSoon() {
    _closing?.cancel();
    _closing = Timer(closeDelay, () {
      if (!_onCard && _hovered != state) state = null;
    });
  }

  /// Closes the card and forgets any wait for one to open: the user has moved
  /// on, or the item has.
  void closeNow() {
    _cancelTimers();
    _hovered = null;
    _onCard = false;
    _regions.clear();
    state = null;
  }

  void pointerDown(int pointer) {
    _pressed.add(pointer);
    _opening?.cancel();
  }

  void pointerUp(int pointer) => _pressed.remove(pointer);

  /// Forgets held pointers whose release nothing will report.
  void clearPointers() => _pressed.clear();
}
