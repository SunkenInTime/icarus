import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/text_widget_height_provider.dart';

class TextWidget extends ConsumerStatefulWidget {
  const TextWidget({
    super.key,
    required this.text,
    this.isFeedback = false,
    required this.id,
    required this.size,
  });
  final double size;
  final String text;
  final bool isFeedback;
  final String id;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _TextWidgetState();
}

class _TextWidgetState extends ConsumerState<TextWidget> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      if (widget.isFeedback == true) return;
      RenderObject? renderObject = context.findRenderObject();
      RenderBox? renderBox = renderObject as RenderBox;
      double height = renderBox.size.height;
      double width = renderBox.size.width;
      Offset offset = Offset(width, height);

      ref
          .read(textWidgetHeightProvider.notifier)
          .updateHeight(widget.id, offset);
    });

    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) return;

    ref.read(textProvider.notifier).editText(_controller.text, widget.id);
  }

  @override
  Widget build(BuildContext context) {
    _controller.text = widget.text;
    return Shortcuts(
      shortcuts: ShortcutInfo.textEditingOverrides,
      child: NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (notification) {
          RenderObject? renderObject = context.findRenderObject();
          RenderBox? renderBox = renderObject as RenderBox;
          double height = renderBox.size.height;
          double width = renderBox.size.width;
          Offset offset = Offset(width, height);
          WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
            ref
                .read(textWidgetHeightProvider.notifier)
                .updateHeight(widget.id, offset);
          });

          return true;
        },
        child: SizeChangedLayoutNotifier(
          child: SizedBox(
            width: widget.size,
            child: IntrinsicHeight(
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                    child: Container(
                      width: 10,
                      color: const Color(0xFFC5C5C5),
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
                            horizontal: 5, vertical: 5),
                        child: TextField(
                          focusNode: _focusNode,
                          controller: _controller,
                          decoration: const InputDecoration(
                            hintText: "Write here...",
                            hintStyle: TextStyle(color: Colors.grey),
                            border: InputBorder.none,
                          ),
                          maxLines: null,
                          minLines: null,
                          expands: true,
                          onTapOutside: (event) {
                            _focusNode.unfocus();
                          },
                        ),
                      ),
                    ),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
