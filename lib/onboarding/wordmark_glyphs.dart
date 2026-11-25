import 'dart:ui';

import 'package:flutter/services.dart' show AssetBundle;
import 'package:path_parsing/path_parsing.dart';

const wordmarkAsset = 'assets/brand/icarus-wordmark.svg';

final class WordmarkGlyphs {
  const WordmarkGlyphs({
    required this.viewBox,
    required this.letters,
    required this.mark,
  });

  final Rect viewBox;
  final List<Path> letters;
  final Path mark;

  static WordmarkGlyphs? _loaded;

  static Future<WordmarkGlyphs> load(AssetBundle bundle) async =>
      _loaded ??= parse(await bundle.loadString(wordmarkAsset));

  static WordmarkGlyphs parse(String svg) {
    final box = RegExp(r'viewBox="([^"]+)"')
        .firstMatch(svg)!
        .group(1)!
        .trim()
        .split(RegExp(r'[\s,]+'))
        .map(double.parse)
        .toList();
    final letters = <Path>[];
    Path? mark;
    for (final tag in RegExp(r'<path\b[^>]*>').allMatches(svg)) {
      final source = tag.group(0)!;
      final data = RegExp(r'\bd="([^"]+)"').firstMatch(source)!.group(1)!;
      final shift =
          RegExp(r'translate\(([-\d.]+)[\s,]+([-\d.]+)\)').firstMatch(source);
      final path = _FlippedPath(
        dx: shift == null ? 0 : double.parse(shift.group(1)!),
        dy: shift == null ? 0 : double.parse(shift.group(2)!),
      );
      writeSvgPathDataToPath(data, path);
      if (source.contains('class="mark"')) {
        mark = path.path;
      } else {
        letters.add(path.path);
      }
    }
    return WordmarkGlyphs(
      viewBox: Rect.fromLTWH(box[0], box[1], box[2], box[3]),
      letters: List.unmodifiable(letters),
      mark: mark!,
    );
  }
}

final class _FlippedPath extends PathProxy {
  _FlippedPath({required this.dx, required this.dy});

  final double dx;
  final double dy;
  final Path path = Path();

  @override
  void moveTo(double x, double y) => path.moveTo(x + dx, -(y + dy));

  @override
  void lineTo(double x, double y) => path.lineTo(x + dx, -(y + dy));

  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) =>
      path.cubicTo(
        x1 + dx,
        -(y1 + dy),
        x2 + dx,
        -(y2 + dy),
        x3 + dx,
        -(y3 + dy),
      );

  @override
  void close() => path.close();
}
