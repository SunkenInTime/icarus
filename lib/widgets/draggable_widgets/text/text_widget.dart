import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_widget_height_provider.dart';

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
    if (isFeedback) {
      return _FeedbackTextWidget(
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

const _textFieldDecoration = InputDecoration(
  hintText: "Write here...",
  hintStyle: TextStyle(color: Colors.grey),
  border: InputBorder.none,
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
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late final TextDraftProvider _draftNotifier;
  late final ProviderSubscription<Map<String, String>> _draftSubscription;

  @override
  void initState() {
    super.initState();
    _draftNotifier = ref.read(textDraftProvider.notifier);
    _controller = TextEditingController(text: _effectiveText());
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

  void _updateMeasuredSize() {
    if (!mounted) return;

    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return;

    final offset = Offset(renderObject.size.width, renderObject.size.height);
    ref.read(textWidgetHeightProvider.notifier).updateHeight(widget.id, offset);
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: ShortcutInfo.textEditingOverrides,
      child: NotificationListener<SizeChangedLayoutNotification>(
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
            child: _SharedTextField(
              controller: _controller,
              focusNode: _focusNode,
              fontSize: widget.fontSize,
              onChanged: (value) {
                _draftNotifier.setDraft(widget.id, value);
              },
              onTapOutside: (_) {
                _focusNode.unfocus();
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedbackTextWidget extends StatefulWidget {
  const _FeedbackTextWidget({
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
  State<_FeedbackTextWidget> createState() => _FeedbackTextWidgetState();
}

class _FeedbackTextWidgetState extends State<_FeedbackTextWidget> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.text);
  }

  @override
  void didUpdateWidget(covariant _FeedbackTextWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;
    _controller.value = TextEditingValue(
      text: widget.text,
      selection: TextSelection.collapsed(offset: widget.text.length),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _TextBoxFrame(
      size: widget.size,
      tagColorValue: widget.tagColorValue,
      child: IgnorePointer(
        child: _SharedTextField(
          controller: _controller,
          fontSize: widget.fontSize,
          readOnly: true,
          enableInteractiveSelection: false,
          showCursor: false,
        ),
      ),
    );
  }
}

class _SharedTextField extends StatelessWidget {
  const _SharedTextField({
    required this.controller,
    required this.fontSize,
    this.focusNode,
    this.readOnly = false,
    this.enableInteractiveSelection = true,
    this.showCursor = true,
    this.onChanged,
    this.onTapOutside,
  });

  final TextEditingController controller;
  final double fontSize;
  final FocusNode? focusNode;
  final bool readOnly;
  final bool enableInteractiveSelection;
  final bool showCursor;
  final ValueChanged<String>? onChanged;
  final TapRegionCallback? onTapOutside;

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    return TextField(
      focusNode: focusNode,
      controller: controller,
      readOnly: readOnly,
      enableInteractiveSelection: enableInteractiveSelection,
      showCursor: showCursor,
      style: TextStyle(
        fontSize: coordinateSystem.worldHeightToScreen(fontSize),
      ),
      decoration: _textFieldDecoration,
      maxLines: null,
      minLines: null,
      expands: true,
      onChanged: onChanged,
      onTapOutside: onTapOutside,
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
