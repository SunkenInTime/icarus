import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  /// How many regions of each item the pointer is in: a shape's whole area
  /// and its center marker report apart.
  final _regions = <String, int>{};

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
      placedItemById(ref.container, id)?.caption?.isNotEmpty ?? false;

  void itemEntered(String id) {
    _regions[id] = (_regions[id] ?? 0) + 1;
    _hovered = id;
    if (id == state) {
      _closing?.cancel();
      return;
    }
    _opening?.cancel();
    if (!_holdsCaption(id)) return;
    _opening = Timer(openDelay, () {
      if (_hovered != id || !_holdsCaption(id)) return;
      _closing?.cancel();
      _onCard = false;
      state = id;
    });
  }

  void itemExited(String id) {
    final left = (_regions[id] ?? 1) - 1;
    if (left > 0) {
      _regions[id] = left;
      return;
    }
    _regions.remove(id);
    if (_hovered != id) return;
    _hovered = null;
    _opening?.cancel();
    if (id == state) _closeSoon();
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
    state = null;
  }
}
