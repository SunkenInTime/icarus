import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_widget_height_provider.dart';
import 'package:icarus/widgets/draggable_widgets/text/formatted_text_view.dart';
import 'package:icarus/widgets/draggable_widgets/text/markup_text_editing_controller.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_format_bar.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_markup.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';

class TextWidget extends ConsumerWidget {
  const TextWidget({
    super.key,
    required this.text,
    this.isFeedback = false,
    required this.id,
    required this.size,
    required this.fontSize,
    this.tagColorValue,
  });

  final double size;
  final double fontSize;
  final String text;
  final bool isFeedback;
  final String id;
  final int? tagColorValue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isFeedback || ref.watch(screenshotProvider)) {
      return _FeedbackTextWidget(
        key: ValueKey(text),
        text: text,
        size: size,
        fontSize: fontSize,
        tagColorValue: tagColorValue,
      );
    }

    return _EditableTextWidget(
      id: id,
      text: text,
      size: size,
      fontSize: fontSize,
      tagColorValue: tagColorValue,
    );
  }
}

const _textVerticalPadding = 21.5;

const _textFieldDecoration = InputDecoration(
  hintText: 'Write here...',
  hintStyle: TextStyle(color: Colors.grey),
  border: InputBorder.none,
  contentPadding: EdgeInsets.symmetric(vertical: _textVerticalPadding),
);

class _EditableTextWidget extends ConsumerStatefulWidget {
  const _EditableTextWidget({
    required this.id,
    required this.text,
    required this.size,
    required this.fontSize,
    this.tagColorValue,
  });

  final String id;
  final String text;
  final double size;
  final double fontSize;
  final int? tagColorValue;

  @override
  ConsumerState<_EditableTextWidget> createState() =>
      _EditableTextWidgetState();
}

class _EditableTextWidgetState extends ConsumerState<_EditableTextWidget> {
  late final MarkupTextEditingController _controller;
  late final FocusNode _focusNode;
  late final TextDraftProvider _draftNotifier;
  late final ProviderSubscription<Map<String, String>> _draftSubscription;
  final _tapGroup = Object();
  final _portalController = OverlayPortalController();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _draftNotifier = ref.read(textDraftProvider.notifier);
    _controller = MarkupTextEditingController(text: _effectiveText());
    _focusNode = FocusNode()..addListener(_onFocusChange);
    _draftSubscription = ref.listenManual<Map<String, String>>(
      textDraftProvider,
      (_, __) => _syncControllerWithExternalState(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateMeasuredSize();
    });
  }

  @override
  void didUpdateWidget(covariant _EditableTextWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.size != widget.size) {
      _syncControllerWithExternalState();
    }
  }

  @override
  void dispose() {
    if (_draftNotifier.draftFor(widget.id) != null) {
      Future<void>.microtask(() {
        _draftNotifier.commitDraft(widget.id);
      });
    }
    _draftSubscription.close();
    _focusNode
      ..removeListener(_onFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  String _effectiveText() {
    return _draftNotifier.draftFor(widget.id) ?? widget.text;
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) return;
    _draftNotifier.commitDraft(widget.id);
    if (!mounted) return;
    setState(() => _editing = false);
    _portalController.hide();
  }

  void _syncControllerWithExternalState() {
    if (!_controller.value.isComposingRangeValid) {
      _controller.clearComposing();
    }
    final nextText = _effectiveText();
    if (_controller.text == nextText) return;
    final selection = _controller.selection;
    final baseOffset = selection.baseOffset.clamp(0, nextText.length).toInt();
    final extentOffset =
        selection.extentOffset.clamp(0, nextText.length).toInt();
    _controller.value = TextEditingValue(
      text: nextText,
      selection: selection.isValid
          ? TextSelection(baseOffset: baseOffset, extentOffset: extentOffset)
          : TextSelection.collapsed(offset: nextText.length),
    );
  }

  TextStyle _bodyStyle(BuildContext context) {
    return Theme.of(context).textTheme.bodyLarge!.copyWith(
          fontSize: CoordinateSystem.instance.worldHeightToScreen(
            widget.fontSize,
          ),
          height: 1,
        );
  }

  void _applyValue(TextEditingValue value) {
    _controller.value = value;
    _draftNotifier.setDraft(widget.id, value.text);
  }

  void _enterEditing() {
    if (_editing) return;
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
      _portalController.show();
    });
  }

  void _updateMeasuredSize() {
    if (!mounted) return;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return;
    ref.read(textWidgetHeightProvider.notifier).updateHeight(
          widget.id,
          Offset(renderObject.size.width, renderObject.size.height),
        );
  }

  @override
  Widget build(BuildContext context) {
    final bodyStyle = _bodyStyle(context);
    final field = _editing
        ? TextField(
            focusNode: _focusNode,
            controller: _controller,
            inputFormatters: [ListContinuationFormatter()],
            groupId: _tapGroup,
            style: bodyStyle,
            decoration: _textFieldDecoration,
            maxLines: null,
            minLines: null,
            expands: true,
            onChanged: (value) => _draftNotifier.setDraft(widget.id, value),
            onTapOutside: (_) => _focusNode.unfocus(),
          )
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _enterEditing,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: _textVerticalPadding,
              ),
              child: ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => FormattedTextView(
                  text: _controller.text,
                  style: bodyStyle,
                  hintText: 'Write here...',
                ),
              ),
            ),
          );

    final measuredFrame = NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (notification) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _updateMeasuredSize();
        });
        return true;
      },
      child: SizeChangedLayoutNotifier(
        child: _TextBoxFrame(
          size: widget.size,
          tagColorValue: widget.tagColorValue,
          child: field,
        ),
      ),
    );

    return TextEditingShortcutScope(
      extraShortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyB, control: true):
            ToggleBoldIntent(),
        SingleActivator(LogicalKeyboardKey.keyB, meta: true):
            ToggleBoldIntent(),
        SingleActivator(LogicalKeyboardKey.keyI, control: true):
            ToggleItalicIntent(),
        SingleActivator(LogicalKeyboardKey.keyI, meta: true):
            ToggleItalicIntent(),
      },
      child: Actions(
        actions: {
          ToggleBoldIntent: CallbackAction<ToggleBoldIntent>(
            onInvoke: (_) {
              _applyValue(MarkupEditing.toggleInline(_controller.value, '**'));
              return null;
            },
          ),
          ToggleItalicIntent: CallbackAction<ToggleItalicIntent>(
            onInvoke: (_) {
              _applyValue(MarkupEditing.toggleInline(_controller.value, '*'));
              return null;
            },
          ),
        },
        child: OverlayPortal.overlayChildLayoutBuilder(
          controller: _portalController,
          overlayChildBuilder: (context, layoutInfo) {
            final childRect = MatrixUtils.transformRect(
              layoutInfo.childPaintTransform,
              Offset.zero & layoutInfo.childSize,
            );
            final overlaySize = layoutInfo.overlaySize;
            final left = (childRect.center.dx - TextFormatBar.width / 2)
                .clamp(8.0, overlaySize.width - TextFormatBar.width - 8)
                .toDouble();
            final below = childRect.bottom + 8;
            final top = below + TextFormatBar.height + 8 <= overlaySize.height
                ? below
                : childRect.top - TextFormatBar.height - 8;
            return Positioned(
              left: left,
              top: top,
              width: TextFormatBar.width,
              height: TextFormatBar.height,
              child: Material(
                color: Colors.transparent,
                child: TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 150),
                  tween: Tween(begin: 0, end: 1),
                  builder: (context, progress, child) => Opacity(
                    opacity: progress,
                    child: Transform.translate(
                      offset: Offset(0, 4 * (1 - progress)),
                      child: child,
                    ),
                  ),
                  child: TextFormatBar(
                    controller: _controller,
                    tapRegionGroupId: _tapGroup,
                    onApply: _applyValue,
                  ),
                ),
              ),
            );
          },
          child: measuredFrame,
        ),
      ),
    );
  }
}

class _FeedbackTextWidget extends StatelessWidget {
  const _FeedbackTextWidget({
    super.key,
    required this.text,
    required this.size,
    required this.fontSize,
    this.tagColorValue,
  });

  final String text;
  final double size;
  final double fontSize;
  final int? tagColorValue;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge!.copyWith(
          fontSize: CoordinateSystem.instance.worldHeightToScreen(fontSize),
          height: 1,
        );
    return _TextBoxFrame(
      size: size,
      tagColorValue: tagColorValue,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: _textVerticalPadding),
        child: FormattedTextView(
          text: text,
          style: style,
          hintText: 'Write here...',
        ),
      ),
    );
  }
}

class _TextBoxFrame extends StatelessWidget {
  const _TextBoxFrame({
    required this.size,
    required this.child,
    this.tagColorValue,
  });

  final double size;
  final Widget child;
  final int? tagColorValue;

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    return SizedBox(
      width: coordinateSystem.worldWidthToScreen(size),
      child: IntrinsicHeight(
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(2)),
              child: Container(
                width: 6,
                color: Color(tagColorValue ?? 0xFFC5C5C5),
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Card(
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(3)),
                ),
                margin: const EdgeInsets.all(0),
                color: Colors.black,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                  ),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
