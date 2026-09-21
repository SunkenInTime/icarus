import 'package:flutter/services.dart';

const double markupHeadingScale = 1.25;

enum MarkupLineKind { paragraph, bullet, numbered, heading }

class MarkupInline {
  const MarkupInline({
    required this.raw,
    this.bold = false,
    this.italic = false,
    this.isMarker = false,
  });

  final String raw;
  final bool bold;
  final bool italic;
  final bool isMarker;
}

class MarkupLine {
  const MarkupLine({
    required this.kind,
    required this.prefix,
    this.number,
    required this.inlines,
  });

  final MarkupLineKind kind;
  final String prefix;
  final int? number;
  final List<MarkupInline> inlines;

  String get plainText => inlines
      .where((inline) => !inline.isMarker)
      .map((inline) => inline.raw)
      .join();
}

final RegExp _bulletPrefix = RegExp(r'^[-*•]\s+');
final RegExp _numberedPrefix = RegExp(r'^\d+[.)]\s+');
final RegExp _headingPrefix = RegExp(r'^#{1,3}\s+');
final RegExp _whitespace = RegExp(r'\s');

List<MarkupLine> parseMarkup(String text) {
  final lines = text.split('\n');
  final result = <MarkupLine>[];
  var previousWasNumbered = false;
  var nextNumber = 1;

  for (final line in lines) {
    final prefixMatch = _linePrefix(line);
    final prefix = prefixMatch?.group(0) ?? '';
    final content = line.substring(prefix.length);
    final kind = prefixMatch == null
        ? MarkupLineKind.paragraph
        : prefix.startsWith('#')
            ? MarkupLineKind.heading
            : _numberedPrefix.hasMatch(prefix)
                ? MarkupLineKind.numbered
                : MarkupLineKind.bullet;
    int? number;
    if (kind == MarkupLineKind.numbered) {
      final typedNumber = int.tryParse(prefix.split(RegExp(r'[.)]')).first);
      if (!previousWasNumbered) {
        nextNumber = typedNumber ?? 1;
      }
      number = nextNumber++;
    } else {
      nextNumber = 1;
    }
    previousWasNumbered = kind == MarkupLineKind.numbered;
    result.add(
      MarkupLine(
        kind: kind,
        prefix: prefix,
        number: number,
        inlines: _parseInline(content),
      ),
    );
  }
  return result;
}

RegExpMatch? _linePrefix(String line) {
  return _bulletPrefix.firstMatch(line) ??
      _numberedPrefix.firstMatch(line) ??
      _headingPrefix.firstMatch(line);
}

List<MarkupInline> _parseInline(String text) {
  final result = <MarkupInline>[];
  var cursor = 0;
  while (cursor < text.length) {
    final match = _inlineOpen(text, cursor);
    if (match == null) {
      final next = _nextInlineOpen(text, cursor + 1);
      final end = next ?? text.length;
      result.add(MarkupInline(raw: text.substring(cursor, end)));
      cursor = end;
      continue;
    }
    final marker = match.marker;
    final close = text.indexOf(marker, match.contentStart);
    if (close <= match.contentStart ||
        (match.marker == '*' &&
            match.contentStart < text.length &&
            _whitespace.hasMatch(text[match.contentStart]))) {
      result.add(MarkupInline(raw: text[cursor]));
      cursor++;
      continue;
    }
    final content = text.substring(match.contentStart, close);
    final nested = _parseInline(content);
    result.add(MarkupInline(
        raw: marker, bold: match.bold, italic: match.italic, isMarker: true));
    if (nested.isEmpty) {
      result.add(MarkupInline(
        raw: content,
        bold: match.bold,
        italic: match.italic,
      ));
    } else {
      result.addAll(
        nested.map(
          (inline) => MarkupInline(
            raw: inline.raw,
            bold: inline.bold || match.bold,
            italic: inline.italic || match.italic,
            isMarker: inline.isMarker,
          ),
        ),
      );
    }
    result.add(MarkupInline(
        raw: marker, bold: match.bold, italic: match.italic, isMarker: true));
    cursor = close + marker.length;
  }
  return result;
}

_InlineOpen? _inlineOpen(String text, int offset) {
  if (text.startsWith('***', offset)) {
    return _InlineOpen('***', offset + 3, bold: true, italic: true);
  }
  if (text.startsWith('**', offset)) {
    return _InlineOpen('**', offset + 2, bold: true);
  }
  if (text[offset] == '*' || text[offset] == '_') {
    final marker = text[offset];
    if (marker == '*' &&
        offset + 1 < text.length &&
        _whitespace.hasMatch(text[offset + 1])) {
      return null;
    }
    return _InlineOpen(marker, offset + 1, italic: true);
  }
  return null;
}

int? _nextInlineOpen(String text, int offset) {
  for (var i = offset; i < text.length; i++) {
    if (_inlineOpen(text, i) != null) return i;
  }
  return null;
}

class _InlineOpen {
  const _InlineOpen(
    this.marker,
    this.contentStart, {
    this.bold = false,
    this.italic = false,
  });

  final String marker;
  final int contentStart;
  final bool bold;
  final bool italic;
}

abstract final class MarkupEditing {
  static TextEditingValue toggleInline(TextEditingValue value, String marker) {
    if (marker != '**' && marker != '*') return value;
    final text = value.text;
    final selection = value.selection;
    if (!selection.isValid) return value;
    if (!selection.isCollapsed) {
      return _toggleSelected(value, marker);
    }

    final word = _wordAtCaret(text, selection.extentOffset);
    if (word != null) {
      final selected = value.copyWith(
        selection:
            TextSelection(baseOffset: word.start, extentOffset: word.end),
      );
      return _toggleSelected(selected, marker);
    }
    final offset = selection.extentOffset.clamp(0, text.length).toInt();
    final next = text.replaceRange(offset, offset, '$marker$marker');
    return value.copyWith(
      text: next,
      selection: TextSelection.collapsed(offset: offset + marker.length),
      composing: TextRange.empty,
    );
  }

  static TextEditingValue _toggleSelected(
      TextEditingValue value, String marker) {
    final text = value.text;
    final selection = value.selection;
    final start = selection.start;
    final end = selection.end;
    var contentStart = start;
    var contentEnd = end;
    while (
        contentStart < contentEnd && _whitespace.hasMatch(text[contentStart])) {
      contentStart++;
    }
    while (contentEnd > contentStart &&
        _whitespace.hasMatch(text[contentEnd - 1])) {
      contentEnd--;
    }
    if (contentStart == contentEnd) return value;
    final leading = text.substring(start, contentStart);
    final trailing = text.substring(contentEnd, end);
    final enclosing = _enclosingMarker(text, contentStart, contentEnd, marker);
    if (enclosing != null) {
      final inner = text.substring(contentStart, contentEnd);
      final replacement = enclosing.replacementMarker == null
          ? '$leading$inner$trailing'
          : '$leading${enclosing.replacementMarker}$inner${enclosing.replacementMarker}$trailing';
      final next =
          text.replaceRange(enclosing.start, enclosing.end, replacement);
      final newStart = enclosing.start + leading.length;
      return value.copyWith(
        text: next,
        selection: TextSelection(
          baseOffset: newStart,
          extentOffset: newStart + (contentEnd - contentStart),
        ),
        composing: TextRange.empty,
      );
    }

    final replacement =
        '$leading$marker${text.substring(contentStart, contentEnd)}$marker$trailing';
    final next = text.replaceRange(start, end, replacement);
    final newStart = start + leading.length + marker.length;
    return value.copyWith(
      text: next,
      selection: TextSelection(
        baseOffset: newStart,
        extentOffset: newStart + contentEnd - contentStart,
      ),
      composing: TextRange.empty,
    );
  }

  static _MarkerRange? _enclosingMarker(
    String text,
    int start,
    int end,
    String marker,
  ) {
    if (marker == '*' &&
        start >= 3 &&
        end + 3 <= text.length &&
        text.substring(start - 3, start) == '***' &&
        text.substring(end, end + 3) == '***') {
      return _MarkerRange(start - 3, end + 3, replacementMarker: '**');
    }
    if (start >= marker.length &&
        end + marker.length <= text.length &&
        text.substring(start - marker.length, start) == marker &&
        text.substring(end, end + marker.length) == marker &&
        !(marker == '*' &&
            ((start >= 2 && text.substring(start - 2, start) == '**') ||
                (end + 2 <= text.length &&
                    text.substring(end, end + 2) == '**')))) {
      return _MarkerRange(start - marker.length, end + marker.length);
    }
    if (marker == '**' &&
        start >= 3 &&
        end + 3 <= text.length &&
        text.substring(start - 3, start) == '***' &&
        text.substring(end, end + 3) == '***') {
      return _MarkerRange(start - 3, end + 3, replacementMarker: '*');
    }
    return null;
  }

  static TextEditingValue toggleLineKind(
    TextEditingValue value,
    MarkupLineKind kind,
  ) {
    final text = value.text;
    final lines = text.split('\n');
    final starts = _lineStarts(lines);
    final selection = value.selection;
    final first = _lineIndexAt(starts, selection.start);
    final last = _lineIndexAt(starts, selection.end);
    final parsed = parseMarkup(text);
    final allMatch = List.generate(
      last - first + 1,
      (index) => parsed[first + index].kind == kind,
    ).every((match) => match);
    var output = StringBuffer();
    var newSelectionBase = 0;
    var newSelectionExtent = 0;
    for (var i = 0; i < lines.length; i++) {
      final oldPrefix = parsed[i].prefix;
      final inSelection = i >= first && i <= last;
      final shouldStrip = kind == MarkupLineKind.paragraph || allMatch;
      final newPrefix = !inSelection
          ? oldPrefix
          : shouldStrip
              ? ''
              : _prefixFor(kind, i, lines);
      final lineStart = starts[i];
      int mapOffset(int offset) {
        final local = (offset - lineStart).clamp(0, lines[i].length).toInt();
        return output.length +
            (local <= oldPrefix.length
                ? newPrefix.length
                : newPrefix.length + local - oldPrefix.length);
      }

      if (selection.baseOffset >= lineStart &&
          selection.baseOffset <= lineStart + lines[i].length) {
        newSelectionBase = mapOffset(selection.baseOffset);
      }
      if (selection.extentOffset >= lineStart &&
          selection.extentOffset <= lineStart + lines[i].length) {
        newSelectionExtent = mapOffset(selection.extentOffset);
      }
      output.write(newPrefix);
      output.write(lines[i].substring(oldPrefix.length));
      if (i != lines.length - 1) output.write('\n');
    }
    var result = value.copyWith(
      text: output.toString(),
      selection: TextSelection(
        baseOffset: newSelectionBase,
        extentOffset: newSelectionExtent,
      ),
      composing: TextRange.empty,
    );
    if (kind == MarkupLineKind.numbered && !allMatch) {
      result = _renumber(result);
    }
    return result;
  }

  static String _prefixFor(
    MarkupLineKind kind,
    int index,
    List<String> lines,
  ) {
    switch (kind) {
      case MarkupLineKind.bullet:
        return '- ';
      case MarkupLineKind.heading:
        return '# ';
      case MarkupLineKind.numbered:
        var ordinal = 1;
        for (var i = index - 1; i >= 0; i--) {
          final match = _numberedPrefix.firstMatch(lines[i]);
          if (match == null) break;
          ordinal++;
        }
        return '$ordinal. ';
      case MarkupLineKind.paragraph:
        return '';
    }
  }

  static TextEditingValue _renumber(TextEditingValue value) {
    final lines = value.text.split('\n');
    final parsed = parseMarkup(value.text);
    final starts = _lineStarts(lines);
    final selected = value.selection;
    final output = StringBuffer();
    var next = 1;
    var inRun = false;
    var base = selected.baseOffset;
    var extent = selected.extentOffset;
    for (var i = 0; i < lines.length; i++) {
      final oldPrefix = parsed[i].prefix;
      var prefix = oldPrefix;
      if (parsed[i].kind == MarkupLineKind.numbered) {
        if (!inRun) {
          next = parsed[i].number ?? 1;
          inRun = true;
        }
        prefix = '$next. ';
        next++;
      } else {
        inRun = false;
      }
      final shift = prefix.length - oldPrefix.length;
      final lineStart = starts[i];
      if (selected.baseOffset >= lineStart &&
          selected.baseOffset <= lineStart + lines[i].length) {
        base += shift;
      }
      if (selected.extentOffset >= lineStart &&
          selected.extentOffset <= lineStart + lines[i].length) {
        extent += shift;
      }
      output.write(prefix);
      output.write(lines[i].substring(oldPrefix.length));
      if (i != lines.length - 1) output.write('\n');
    }
    return value.copyWith(
      text: output.toString(),
      selection: TextSelection(baseOffset: base, extentOffset: extent),
    );
  }

  static bool isInlineActive(TextEditingValue value, String marker) {
    final position = value.selection.extentOffset;
    final lines = parseMarkup(value.text);
    var offset = 0;
    for (final line in lines) {
      final lineEnd = offset +
          line.prefix.length +
          line.inlines.fold<int>(0, (sum, inline) => sum + inline.raw.length);
      if (position <= lineEnd) {
        var cursor = offset + line.prefix.length;
        for (final inline in line.inlines) {
          final end = cursor + inline.raw.length;
          if (position >= cursor &&
              position <= end &&
              !inline.isMarker &&
              ((marker == '**' && inline.bold) ||
                  (marker == '*' && inline.italic))) {
            return true;
          }
          cursor = end;
        }
        return false;
      }
      offset = lineEnd + 1;
    }
    return false;
  }

  static MarkupLineKind lineKindAt(TextEditingValue value) {
    final lines = value.text.split('\n');
    final starts = _lineStarts(lines);
    final first = _lineIndexAt(starts, value.selection.start);
    final last = _lineIndexAt(starts, value.selection.end);
    final parsed = parseMarkup(value.text);
    final kind = parsed[first].kind;
    if (first != last &&
        parsed
            .skip(first)
            .take(last - first + 1)
            .any((line) => line.kind != kind)) {
      return MarkupLineKind.paragraph;
    }
    return kind;
  }

  static TextEditingValue continueList(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final oldSelection = oldValue.selection;
    if (!oldSelection.isCollapsed ||
        newValue.text !=
            oldValue.text.replaceRange(
              oldSelection.extentOffset,
              oldSelection.extentOffset,
              '\n',
            )) {
      return newValue;
    }
    final oldLines = oldValue.text.split('\n');
    final starts = _lineStarts(oldLines);
    final lineIndex = _lineIndexAt(starts, oldSelection.extentOffset);
    final parsed = parseMarkup(oldValue.text);
    final line = parsed[lineIndex];
    if (line.kind != MarkupLineKind.bullet &&
        line.kind != MarkupLineKind.numbered) {
      return newValue;
    }
    final lineStart = starts[lineIndex];
    final content = oldValue.text.substring(
      lineStart + line.prefix.length,
      lineStart + oldLines[lineIndex].length,
    );
    if (content.isEmpty) {
      final withoutPrefix = oldValue.text.replaceRange(
        lineStart,
        lineStart + line.prefix.length,
        '',
      );
      return TextEditingValue(
        text: withoutPrefix,
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }
    final continuation = line.kind == MarkupLineKind.bullet
        ? line.prefix
        : '${(line.number ?? 1) + 1}. ';
    final insertedAt = oldSelection.extentOffset + 1;
    final continued =
        newValue.text.replaceRange(insertedAt, insertedAt, continuation);
    return line.kind == MarkupLineKind.numbered
        ? _renumber(
            newValue.copyWith(
              text: continued,
              selection: TextSelection.collapsed(
                offset: insertedAt + continuation.length,
              ),
            ),
          )
        : newValue.copyWith(
            text: continued,
            selection: TextSelection.collapsed(
              offset: insertedAt + continuation.length,
            ),
          );
  }

  static List<int> _lineStarts(List<String> lines) {
    final starts = <int>[];
    var offset = 0;
    for (final line in lines) {
      starts.add(offset);
      offset += line.length + 1;
    }
    return starts;
  }

  static int _lineIndexAt(List<int> starts, int offset) {
    for (var i = starts.length - 1; i >= 0; i--) {
      if (offset >= starts[i]) return i;
    }
    return 0;
  }

  static _WordRange? _wordAtCaret(String text, int caret) {
    if (text.isEmpty) return null;
    var position = caret.clamp(0, text.length).toInt();
    if (position == text.length || !_wordCharacter(text[position])) {
      if (position > 0 && _wordCharacter(text[position - 1])) position--;
    }
    if (position >= text.length || !_wordCharacter(text[position])) {
      return null;
    }
    var start = position;
    var end = position + 1;
    while (start > 0 && _wordCharacter(text[start - 1])) start--;
    while (end < text.length && _wordCharacter(text[end])) end++;
    return _WordRange(start, end);
  }

  static bool _wordCharacter(String character) =>
      RegExp(r'[A-Za-z0-9]').hasMatch(character);
}

class _MarkerRange {
  const _MarkerRange(this.start, this.end, {this.replacementMarker});

  final int start;
  final int end;
  final String? replacementMarker;
}

class _WordRange {
  const _WordRange(this.start, this.end);

  final int start;
  final int end;
}

class ListContinuationFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return MarkupEditing.continueList(oldValue, newValue);
  }
}
