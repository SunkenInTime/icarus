import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/caption_links.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/canvas_selection_layer.dart';
import 'package:icarus/widgets/caption_markers.dart';
import 'package:icarus/widgets/draggable_widgets/caption_menu.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:url_launcher/url_launcher.dart';

/// The name a caption card shows for [item].
String captionItemName(AppLocalizations l10n, PlacedWidget item) =>
    switch (item) {
      PlacedAgentNode() =>
        switch (AgentData.agents[item.type]?.name) {
          final name? => l10n.gameName(name),
          null => l10n.captionCardAgentName,
        },
      PlacedAbility() => l10n.gameName(item.data.name),
      PlacedText() => l10n.captionCardTextName,
      PlacedImage() => l10n.captionCardImageName,
      PlacedUtility() when item.type == UtilityType.spike => l10n.gameSpike,
      PlacedUtility() when UtilityData.isViewCone(item.type) =>
        l10n.captionCardVisionConeName,
      _ => l10n.captionCardShapeName,
    };

/// The caption card of the item that's open, above that item, or below it
/// when above is covered. It sits outside the canvas, so presses and the wheel
/// stay on it, and it keeps its size at every zoom.
///
/// The same card is where a note is written: Create caption and Edit caption
/// open it with the note in a text field, and an editor can click into a card
/// they're reading. Enter starts a new line, Ctrl+Enter (Cmd+Enter on a Mac)
/// or a press anywhere off the card saves, and Escape drops what was typed.
class CaptionCardLayer extends ConsumerStatefulWidget {
  const CaptionCardLayer({required this.transformation, super.key});

  /// The canvas's zoom and pan: moving it closes a card being read, and a
  /// card being written follows its item.
  final TransformationController transformation;

  @override
  ConsumerState<CaptionCardLayer> createState() => _CaptionCardLayerState();
}

class _CaptionCardLayerState extends ConsumerState<CaptionCardLayer>
    with WidgetsBindingObserver {
  final _card = GlobalKey();
  _Placement? _placement;

  /// The note being written, while the card is open for writing.
  _Draft? _draft;

  /// Where the cursor starts in the next draft: the spot clicked in the card.
  int? _clickedAt;

  late final ProviderContainer _container;
  late final CaptionCardNotifier _notifier =
      ref.read(captionCardProvider.notifier);

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _notifier.clearPointers();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addObserver(this);
    widget.transformation.addListener(_onTransform);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    widget.transformation.removeListener(_onTransform);
    final draft = _draft;
    _draft = null;
    // The editor went away, maybe with a note open. It's kept, as a click
    // elsewhere would keep it, once the tree has finished coming down, and
    // writing ends either way.
    final container = _container;
    final notifier = _notifier;
    Future<void>.microtask(() {
      if (draft != null) _save(container, draft);
      notifier.stopWriting();
      draft?.dispose();
    });
    super.dispose();
  }

  /// Whether the card is open for writing. The draft comes with the card's
  /// first build, so it can be missing while this is true.
  bool get _writing => ref.read(writingCaptionProvider);

  void _onTransform() {
    if (!_writing) {
      _notifier.closeNow();
      return;
    }
    // The item is only at its new place once the canvas has drawn at the new
    // zoom.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  bool _onCard(Offset position) {
    final box = _card.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    return (Offset.zero & box.size).contains(box.globalToLocal(position));
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _notifier.pointerDown(event.pointer);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _notifier.pointerUp(event.pointer);
    }
    // A note being written decides for itself what a press off it means: its
    // field's menu and handles can sit outside the card.
    if (_writing || _onCard(event.position)) return;
    if (event is PointerDownEvent || event is PointerSignalEvent) {
      _notifier.closeNow();
    }
  }

  /// Escape closes a card being read. A note being written handles its own,
  /// since its field may want the key first.
  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _notifier.closeNow();
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A note being written stays open while the user fetches a link from
    // another window.
    if (state != AppLifecycleState.resumed) _notifier.closeNow();
  }

  /// The user moved on: a note being written is saved, a card being read
  /// closes.
  void _leave() {
    if (_writing) {
      _finish(save: true);
    } else {
      _notifier.closeNow();
    }
  }

  /// Ends writing, saving the note first when [save]. The item can go before
  /// the card first builds, with no draft yet, and writing still ends then, or
  /// the app's shortcuts would stay off.
  void _finish({required bool save}) {
    final draft = _draft;
    _draft = null;
    if (draft != null && save) _save(_container, draft);
    _notifier.stopWriting();
    // The field holds them until the card is gone.
    if (draft != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => draft.dispose());
    }
  }

  /// The draft for [open], made when the card opens for writing.
  _Draft _draftFor(OpenCaption open, String start) {
    final current = _draft;
    if (current != null && current.open == open) return current;
    final draft = _Draft(open, start, cursor: _clickedAt ?? start.length);
    _clickedAt = null;
    _draft = draft;
    if (current != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
    }
    // Opened from a menu that is still closing, which hands focus back to the
    // canvas: an autofocus here would lose it, and the note would be typed
    // into the app's shortcuts.
    void takeFocus() {
      if (mounted && _draft == draft && !draft.focus.hasFocus) {
        draft.focus.requestFocus();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => takeFocus());
    Future<void>.delayed(const Duration(milliseconds: 250), takeFocus);
    // A press in another text field, such as a shape's size in the sidebar,
    // is inside the card's tap region: Flutter puts every text field and the
    // field's Cut, Copy and Paste menu in one group. So the keyboard landing
    // in another field is what saves the note then. Losing it to the canvas
    // as a menu closes, or to another window, doesn't.
    draft.focus.addListener(() {
      if (draft.focus.hasFocus) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _draft == draft &&
            !draft.focus.hasFocus &&
            isTypingInTextField()) {
          _finish(save: true);
        }
      });
    });
    return draft;
  }

  /// Opens the card being read for writing, with the cursor at [offset] in
  /// its note.
  void _write(String id, int offset) {
    _clickedAt = offset;
    _notifier.startWriting(id, currentCaptionPlace(_container));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(captionCardProvider, (previous, next) {
      // Reading a card and then writing in it keeps it where it is.
      if (previous?.id != next?.id) _placement = null;
    });
    ref.listen(interactionStateProvider, (_, __) => _leave());
    ref.listen(
      strategyPageSessionProvider.select((session) => session.activePageId),
      (_, __) => _leave(),
    );
    ref.listen(hoveredLineUpTargetProvider, (_, target) {
      if (target != null) _notifier.closeNow();
    });
    ref.listen(
      appPreferencesProvider.select((preferences) => preferences.showCaptions),
      (_, visible) {
        if (!visible) _notifier.closeNow();
      },
    );

    final open = ref.watch(captionCardProvider);
    final canEdit = ref.watch(
      currentStrategyCapabilitiesProvider.select(
        (capabilities) => capabilities.canEditPages,
      ),
    );
    // Keeps the card on its item, and its text current, when a teammate moves
    // or changes it.
    ref.watch(agentProvider);
    ref.watch(abilityProvider);
    ref.watch(textProvider);
    ref.watch(placedImageProvider);
    ref.watch(utilityProvider);
    if (open == null) return const SizedBox.shrink();
    final id = open.id;

    final item = placedItemById(_container, id);
    final caption = item?.caption ?? '';
    final registry = ref.read(canvasItemRegistryProvider);
    final stack = context.findAncestorRenderObjectOfType<RenderStack>();
    Rect? outline;
    final obstacles = <Rect>[];
    if (stack != null) {
      for (final (item: outlined, :corners) in registry.itemsIn(stack)) {
        if (outlined.id != id) continue;
        outline = _bounds(corners);
        break;
      }
      obstacles.addAll(registry.chromeIn(stack));
      if (registry.handleIn(stack, id) case final handle?) {
        obstacles.add(handle);
      }
    }
    if (item == null || outline == null || (!open.writing && caption.isEmpty)) {
      // The item went while the card was open, a teammate cleared its note, or
      // the page moved on. A note being written is saved if it still can be,
      // or handed to the clipboard.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (open.writing) {
          _finish(save: true);
        } else {
          _notifier.closeNow();
        }
      });
      return const SizedBox.shrink();
    }

    final draft = open.writing ? _draftFor(open, caption) : null;
    final name = captionItemName(context.l10n, item);
    final placement = _placement ??= _Placement();
    return CustomSingleChildLayout(
      delegate: _CaptionCardLayout(
        item: outline,
        obstacles: obstacles,
        placement: placement,
      ),
      child: MouseRegion(
        key: _card,
        onEnter: (_) => _notifier.cardEntered(),
        onExit: (_) => _notifier.cardExited(),
        child: ListenableBuilder(
          listenable: placement,
          builder: (context, _) => Padding(
            // Part of the card, so there's no gap to cross on the way to it.
            padding: placement.above
                ? const EdgeInsets.only(bottom: _CaptionCardLayout.gapAbove)
                : const EdgeInsets.only(top: _CaptionCardLayout.gapBelow),
            child: draft != null
                ? _CaptionEditor(
                    name: name,
                    draft: draft,
                    onSave: () => _finish(save: true),
                    onDrop: () => _finish(save: false),
                  )
                : _CaptionCard(
                    name: name,
                    caption: caption,
                    onWrite: canEdit ? (offset) => _write(id, offset) : null,
                  ),
          ),
        ),
      ),
    );
  }

  static Rect _bounds(List<Offset> corners) {
    var bounds = Rect.fromPoints(corners.first, corners.first);
    for (final corner in corners) {
      bounds = bounds.expandToInclude(Rect.fromPoints(corner, corner));
    }
    return bounds;
  }
}

/// Writes [draft] onto its item, if it changed. Clearing the text removes the
/// caption.
void _save(ProviderContainer container, _Draft draft) {
  final text = draft.controller.text.trim();
  if (text == draft.start) return;
  if (finishCaption(container, draft.id, draft.place, text)) return;
  // A teammate deleted the item, or its page went, while the note was being
  // written.
  unawaited(Clipboard.setData(ClipboardData(text: text)));
  Settings.showToast(
    message: container.read(l10nProvider).captionCardItemGone,
    backgroundColor: Settings.tacticalVioletTheme.destructive,
  );
}

/// A note being written in a card: the text so far, and where it started.
class _Draft {
  _Draft(this.open, this.start, {required int cursor})
      : controller = TextEditingController.fromValue(
          TextEditingValue(
            text: start,
            selection: TextSelection.collapsed(
              offset: cursor.clamp(0, start.length),
            ),
          ),
        );

  final OpenCaption open;

  /// The caption when writing began.
  final String start;
  final TextEditingController controller;
  final focus = FocusNode(debugLabel: 'caption');

  /// The field whose Cut, Copy and Paste menu is open, if it is.
  EditableTextState? menuOf;

  String get id => open.id;
  CaptionPlace get place => open.writingAt!;

  void dispose() {
    focus.dispose();
    controller.dispose();
  }
}

/// The side a card opened on, fixed until it closes: a rotate handle hides a
/// moment after the pointer leaves the item, and the card must not jump away
/// from the pointer on its way over.
class _Placement extends ChangeNotifier {
  bool above = true;
  bool chosen = false;

  void choose(bool value) {
    chosen = true;
    if (value == above) return;
    above = value;
    WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }
}

class _CaptionCardLayout extends SingleChildLayoutDelegate {
  _CaptionCardLayout({
    required this.item,
    required this.obstacles,
    required this.placement,
  });

  /// Above, the gap also clears the marker, so the note never hides it.
  static const gapAbove = 10.0;
  static const gapBelow = 8.0;
  static const width = 280.0;
  static const _margin = 8.0;

  final Rect item;
  final List<Rect> obstacles;
  final _Placement placement;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: width,
        minWidth: width,
        maxHeight: constraints.maxHeight - 2 * _margin,
      );

  bool _clear(Rect card, Size size, List<Rect> around) =>
      card.top >= _margin &&
      card.bottom <= size.height - _margin &&
      !around.any(card.overlaps);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final around = obstacles;
    final left = (item.center.dx - childSize.width / 2).clamp(
      _margin,
      math.max<double>(_margin, size.width - childSize.width - _margin),
    );
    final aboveTop = item.top - childSize.height;
    final belowTop = item.bottom;
    Rect at(double top) => Offset(left, top) & childSize;
    if (!placement.chosen) {
      final above = _clear(at(aboveTop), size, around) ||
          !_clear(at(belowTop), size, around) &&
              item.top >= size.height - item.bottom;
      placement.choose(above);
    }
    final top = placement.above ? aboveTop : belowTop;
    return Offset(
      left,
      top.clamp(_margin, size.height - childSize.height - _margin),
    );
  }

  @override
  bool shouldRelayout(_CaptionCardLayout oldDelegate) =>
      item != oldDelegate.item || placement != oldDelegate.placement;
}

/// How a note reads in a card, written or being written.
TextStyle _noteStyle() => TextStyle(
      color: Settings.tacticalVioletTheme.foreground,
      fontSize: 14,
      height: 20 / 14,
    );

const _notePadding = EdgeInsets.fromLTRB(12, 10, 12, 10);

/// The card around a note: the item's name over the note, on the surface of
/// the item name card.
class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.name, required this.body, this.trailing});

  final String name;
  final Widget body;

  /// Beside the name, at the header's far end.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final edge = Settings.tacticalVioletTheme.border;
    final border = BorderSide(color: edge, width: 2);
    final muted = TextStyle(
      color: Settings.tacticalVioletTheme.mutedForeground,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      height: 16 / 12,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Settings.abilityBGColor,
        border: Border.fromBorderSide(border),
        borderRadius: BorderRadius.circular(4),
        boxShadow: const [Settings.cardForegroundBackdrop],
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: edge)),
              ),
              child: Row(
                children: [
                  const CustomPaint(
                    size: Size(12, 11),
                    painter: _CaptionGlyphPainter(),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                  if (trailing case final trailing?)
                    DefaultTextStyle.merge(
                      style: muted.copyWith(fontWeight: FontWeight.w400),
                      child: trailing,
                    ),
                ],
              ),
            ),
            Flexible(child: body),
          ],
        ),
      ),
    );
  }
}

class _CaptionCard extends StatefulWidget {
  const _CaptionCard({
    required this.name,
    required this.caption,
    required this.onWrite,
  });

  final String name;
  final String caption;

  /// Opens the note for writing with the cursor at the offset clicked, or
  /// null for a reader who can't edit.
  final void Function(int offset)? onWrite;

  @override
  State<_CaptionCard> createState() => _CaptionCardState();
}

class _CaptionCardState extends State<_CaptionCard> {
  final _links = <TapGestureRecognizer>[];
  final _note = GlobalKey();

  @override
  void dispose() {
    _disposeLinks();
    super.dispose();
  }

  void _disposeLinks() {
    for (final link in _links) {
      link.dispose();
    }
    _links.clear();
  }

  List<InlineSpan> _spans() {
    _disposeLinks();
    return [
      for (final run in captionRuns(widget.caption))
        if (run.uri case final uri?)
          TextSpan(
            text: run.text,
            style: const TextStyle(
              color: Settings.accentInk,
              decoration: TextDecoration.underline,
              decorationColor: Settings.accentInk,
            ),
            mouseCursor: SystemMouseCursors.click,
            recognizer: (TapGestureRecognizer()
                  ..onTap = () => launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      ))
                .also(_links.add),
          )
        else
          TextSpan(text: run.text),
    ];
  }

  /// Where in the note [position] is: the character clicked, or the end when
  /// the click was off the text. A link takes its own click first.
  int _offsetAt(Offset position) {
    final paragraph = _note.currentContext?.findRenderObject();
    if (paragraph is! RenderParagraph || !paragraph.hasSize) {
      return widget.caption.length;
    }
    final local = paragraph.globalToLocal(position);
    if (!(Offset.zero & paragraph.size).contains(local)) {
      return widget.caption.length;
    }
    return paragraph.getPositionForOffset(local).offset;
  }

  @override
  Widget build(BuildContext context) {
    final onWrite = widget.onWrite;
    final card = _CardFrame(
      name: widget.name,
      body: SingleChildScrollView(
        padding: _notePadding,
        child: Text.rich(
          key: _note,
          TextSpan(children: _spans()),
          style: _noteStyle(),
        ),
      ),
    );
    if (onWrite == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => onWrite(_offsetAt(details.globalPosition)),
        child: card,
      ),
    );
  }
}

class _SaveCaptionIntent extends Intent {
  const _SaveCaptionIntent();
}

class _StayIntent extends Intent {
  const _StayIntent();
}

class _DropCaptionIntent extends Intent {
  const _DropCaptionIntent();
}

/// Escape drops the note, unless the field is using the key: to close its
/// Cut, Copy and Paste menu, or to cancel a word being composed.
class _DropCaptionAction extends Action<_DropCaptionIntent> {
  _DropCaptionAction(this.draft, this.onDrop);

  final _Draft draft;
  final VoidCallback onDrop;

  @override
  bool isEnabled(_DropCaptionIntent intent, [BuildContext? context]) =>
      !draft.controller.value.composing.isValid;

  @override
  Object? invoke(_DropCaptionIntent intent) {
    if (draft.menuOf case final field?) {
      field.hideToolbar(false);
    } else {
      onDrop();
    }
    return null;
  }
}

/// The field's Cut, Copy and Paste menu, which tells its draft while it's
/// open.
class _CaptionFieldMenu extends StatefulWidget {
  const _CaptionFieldMenu({required this.draft, required this.field});

  final _Draft draft;
  final EditableTextState field;

  @override
  State<_CaptionFieldMenu> createState() => _CaptionFieldMenuState();
}

class _CaptionFieldMenuState extends State<_CaptionFieldMenu> {
  @override
  void initState() {
    super.initState();
    widget.draft.menuOf = widget.field;
  }

  @override
  void dispose() {
    if (widget.draft.menuOf == widget.field) widget.draft.menuOf = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AdaptiveTextSelectionToolbar.editableText(
          editableTextState: widget.field);
}

/// The card with its note in a text field. What's typed looks as it will
/// read, and no key typed here reaches the app's shortcuts.
class _CaptionEditor extends StatelessWidget {
  const _CaptionEditor({
    required this.name,
    required this.draft,
    required this.onSave,
    required this.onDrop,
  });

  final String name;
  final _Draft draft;
  final VoidCallback onSave;
  final VoidCallback onDrop;

  static bool get _mac =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final style = _noteStyle();
    final field = TextField(
      controller: draft.controller,
      focusNode: draft.focus,
      style: style,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      inputFormatters: [LengthLimitingTextInputFormatter(captionMaxLength)],
      decoration: InputDecoration.collapsed(
        hintText: context.l10n.captionCardHint,
        hintStyle: style.copyWith(
          color: Settings.tacticalVioletTheme.mutedForeground,
        ),
      ),
      // A press off the card saves the note, and the card sees to it.
      onTapOutside: (_) {},
      contextMenuBuilder: (_, field) =>
          _CaptionFieldMenu(draft: draft, field: field),
    );
    return Material(
      type: MaterialType.transparency,
      // The card, the field's menu and its handles are one region: a press
      // anywhere else saves the note, whether or not the keyboard reached the
      // field yet. A press on the card's header or edge keeps the keyboard in
      // the field.
      child: TextFieldTapRegion(
        onTapOutside: (_) => onSave(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: draft.focus.requestFocus,
          child: _CardFrame(
            name: name,
            trailing: Text(
              context.l10n.captionCardSaveShortcut(
                _mac ? '⌘Enter' : 'Ctrl+Enter',
              ),
            ),
            // Keys bound to the app's shortcuts stop at the field, so a letter
            // typed into a note never deletes or turns what's under the
            // pointer.
            body: TextEditingShortcutScope(
              extraShortcuts: const {
                SingleActivator(LogicalKeyboardKey.enter, control: true):
                    _SaveCaptionIntent(),
                SingleActivator(LogicalKeyboardKey.enter, meta: true):
                    _SaveCaptionIntent(),
                SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
                    _SaveCaptionIntent(),
                SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true):
                    _SaveCaptionIntent(),
                // Tab would carry the keyboard out of the note, and the next
                // letters into the app's shortcuts.
                SingleActivator(LogicalKeyboardKey.tab): _StayIntent(),
                SingleActivator(LogicalKeyboardKey.tab, shift: true):
                    _StayIntent(),
                SingleActivator(LogicalKeyboardKey.escape):
                    _DropCaptionIntent(),
              },
              child: Actions(
                actions: {
                  _SaveCaptionIntent: CallbackAction<_SaveCaptionIntent>(
                    onInvoke: (_) {
                      onSave();
                      return null;
                    },
                  ),
                  _StayIntent: DoNothingAction(),
                  _DropCaptionIntent: _DropCaptionAction(draft, onDrop),
                },
                child: Padding(padding: _notePadding, child: field),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 15);
    canvas.drawPath(
      captionMarkerPath,
      Paint()..color = Settings.tacticalVioletTheme.mutedForeground,
    );
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter oldDelegate) => false;
}

extension<T> on T {
  T also(void Function(T value) use) {
    use(this);
    return this;
  }
}
