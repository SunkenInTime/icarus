import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/text_provider.dart';

class TextWidget extends ConsumerStatefulWidget {
  const TextWidget({
    super.key,
    required this.text,
    this.isDragged,
    required this.id,
    required this.size,
  });
  final double size;
  final String text;
  final bool? isDragged;
  final String id;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _TextWidgetState();
}

class _TextWidgetState extends ConsumerState<TextWidget> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  final GlobalKey _textFieldKey = GlobalKey();
  @override
  void initState() {
    super.initState();
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
  void didUpdateWidget(covariant TextWidget oldWidget) {
    log("Hey we updated like a freaking boss");
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    _controller.text = widget.text;
    return Shortcuts(
      shortcuts: ShortcutInfo.textEditingOverrides,
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
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
    );
  }
}
