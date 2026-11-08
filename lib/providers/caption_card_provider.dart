import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/draggable_widgets/caption_menu.dart';

/// The caption card on screen: the item it belongs to, and where its note is
/// being written, if it is.
@immutable
class OpenCaption {
  const OpenCaption(this.id, {this.writingAt});

  final String id;

  /// The strategy and page the note is being written on, or null when the
  /// card is only being read. An item copied to another page keeps its id, so
  /// a note is only ever saved where it was started.
  final CaptionPlace? writingAt;

  bool get writing => writingAt != null;

  @override
  bool operator ==(Object other) =>
      other is OpenCaption && other.id == id && other.writingAt == writingAt;

  @override
  int get hashCode => Object.hash(id, writingAt);

  @override
  String toString() => writing ? 'writing $id' : id;
}

/// The caption card that's open, or null, for the pointer's journey from an
/// item to its card, and for writing a note in place.
final captionCardProvider = NotifierProvider<CaptionCardNotifier, OpenCaption?>(
    CaptionCardNotifier.new);

/// Whether a note is being written in a caption card. The app's shortcuts
/// are off for as long as it is, wherever the keyboard is: a menu closing as
/// the card opens hands the keyboard to the canvas for a moment, and a letter
/// typed then must not delete or turn what's under the pointer.
final writingCaptionProvider = Provider<bool>(
  (ref) =>
      ref.watch(captionCardProvider.select((open) => open?.writing ?? false)),
);

class CaptionCardNotifier extends Notifier<OpenCaption?> {
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
  OpenCaption? build() {
    ref.onDispose(_cancelTimers);
    return null;
  }

  void _cancelTimers() {
    _opening?.cancel();
    _closing?.cancel();
  }

  /// A note being written holds the card where it is. Hovering, leaving and
  /// the ways a read card closes all wait until the writer saves or backs out,
  /// which only [stopWriting] does.
  bool get _writing => state?.writing ?? false;

  bool _holdsCaption(String id) =>
      ref.read(appPreferencesProvider).showCaptions &&
      (placedItemById(ref.container, id)?.caption?.isNotEmpty ?? false);

  /// The pointer entered [region] of the item [id].
  void itemEntered(String id, Object region) {
    _regions[region] = id;
    _hovered = id;
    if (_writing) return;
    if (id == state?.id) {
      _closing?.cancel();
      return;
    }
    _opening?.cancel();
    if (_pressed.isNotEmpty || !_holdsCaption(id)) return;
    _opening = Timer(openDelay, () {
      if (_writing) return;
      if (_hovered != id || _pressed.isNotEmpty || !_holdsCaption(id)) return;
      _closing?.cancel();
      _onCard = false;
      state = OpenCaption(id);
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
    if (id == state?.id) _closeSoon();
  }

  /// Opens the card of [id] at once: a tap has no pointer to wait on.
  void openNow(String id) {
    if (_writing) return;
    _cancelTimers();
    if (_holdsCaption(id)) state = OpenCaption(id);
  }

  /// Opens the card of [id] for writing its note, at [place]. Show captions
  /// doesn't stop this: the user asked for it.
  void startWriting(String id, CaptionPlace place) {
    _cancelTimers();
    _onCard = false;
    state = OpenCaption(id, writingAt: place);
  }

  /// The note was saved or dropped. The card closes, and opens again by
  /// hovering as usual.
  void stopWriting() {
    if (!_writing) return;
    _cancelTimers();
    _hovered = null;
    _onCard = false;
    _regions.clear();
    state = null;
  }

  void cardEntered() {
    _onCard = true;
    _closing?.cancel();
  }

  void cardExited() {
    _onCard = false;
    if (_hovered != state?.id) _closeSoon();
  }

  void _closeSoon() {
    if (_writing) return;
    _closing?.cancel();
    _closing = Timer(closeDelay, () {
      if (!_writing && !_onCard && _hovered != state?.id) state = null;
    });
  }

  /// Closes the card and forgets any wait for one to open: the user has moved
  /// on, or the item has. A note being written stays open.
  void closeNow() {
    if (_writing) return;
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
