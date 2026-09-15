import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:path_parsing/path_parsing.dart';
import 'package:xml/xml.dart';

/// SVG destinations that can receive visibility. This is not collision geometry.
///
/// A destination must be in the painted map, but the segment leading to it may
/// leave and re-enter that paint. SVG walls with associated height/opening data
/// determine occlusion. Parse each side's SVG rather than reflecting the other.
/// Coordinates remain in the SVG viewBox until the caller applies BoxFit.contain.
class WorldReceiverMask {
  WorldReceiverMask._(this.viewBox, List<ReceiverFill> fills)
      : fills = List.unmodifiable(fills);

  final Rect viewBox;
  final List<ReceiverFill> fills;

  factory WorldReceiverMask.parse(String source) {
    final root = XmlDocument.parse(source).rootElement;
    if (root.name.local != 'svg') {
      throw const FormatException('Receiver source must be an SVG.');
    }
    final box = _numbers(root.getAttribute('viewBox') ?? '');
    if (box.length != 4 || box[2] <= 0 || box[3] <= 0) {
      throw const FormatException(
          'A finite, positive SVG viewBox is required.');
    }
    if (root.descendants.whereType<XmlElement>().any(
          (element) => element.name.local == 'style',
        )) {
      throw const FormatException(
          'Stylesheets require SVG renderer resolution.');
    }
    final fills = <ReceiverFill>[];

    void visit(XmlElement element, Map<String, String> inherited,
        _Affine parentTransform, List<XmlElement> ancestors) {
      final name = element.name.local;
      if (const {'defs', 'clipPath', 'mask', 'symbol', 'pattern', 'marker'}
          .contains(name)) {
        return;
      }
      final properties = <String, String>{...inherited};
      for (final key in const [
        'fill',
        'fill-rule',
        'fill-opacity',
        'visibility'
      ]) {
        final value = _property(element, key);
        if (value != null && value != 'inherit') properties[key] = value;
      }
      if (_property(element, 'display') == 'none') return;
      final transform = parentTransform.multiply(
        _Affine.parse(element.getAttribute('transform') ?? ''),
      );
      final lineage = [...ancestors, element];
      if (name == 'use') {
        throw const FormatException(
            'Resolve SVG use elements before extraction.');
      }
      if (properties['fill']?.toLowerCase() == '#271406' &&
          properties['visibility'] != 'hidden' &&
          properties['visibility'] != 'collapse') {
        if (name == 'path') {
          for (final ancestor in lineage) {
            for (final key in const ['clip-path', 'mask', 'filter']) {
              final value = _property(ancestor, key);
              if (value != null && value != 'none') {
                throw FormatException('Receiver path has unsupported $key.');
              }
            }
            if (ancestor != root && ancestor.name.local == 'svg') {
              throw const FormatException(
                  'Nested SVG viewports are unsupported.');
            }
          }
          // Positive artwork opacity still paints the destination. Haven uses
          // 0.9 on an extra base path; that does not mean 90% visibility there.
          if (lineage
                  .any((node) => _opacity(_property(node, 'opacity')) == 0) ||
              _opacity(properties['fill-opacity']) == 0) {
            return;
          }
          final d = element.getAttribute('d');
          if (d == null || d.trim().isEmpty) return;
          if (RegExp('[Aa]').hasMatch(d)) {
            throw const FormatException(
                'Elliptical arcs need a native arc representation, not cubic approximation.');
          }
          final rule = properties['fill-rule'] ?? 'nonzero';
          if (rule != 'nonzero' && rule != 'evenodd') {
            throw FormatException('Unsupported receiver fill-rule: $rule.');
          }
          final proxy = _ExactPathProxy();
          writeSvgPathDataToPath(d, proxy);
          proxy.path.fillType =
              rule == 'evenodd' ? PathFillType.evenOdd : PathFillType.nonZero;
          fills.add(ReceiverFill._(
            proxy.path.transform(transform.matrix),
            d,
            rule,
            proxy.subpaths,
            proxy.cubics,
          ));
        } else if (const {'rect', 'circle', 'ellipse', 'polygon', 'polyline'}
            .contains(name)) {
          throw FormatException('Convert base-filled $name to an SVG path.');
        }
      }
      for (final child in element.childElements) {
        visit(child, properties, transform, lineage);
      }
    }

    visit(root, const {}, const _Affine.identity(), const []);
    if (fills.isEmpty) {
      throw const FormatException('No rendered #271406 receiver paths.');
    }
    return WorldReceiverMask._(
        Rect.fromLTWH(box[0], box[1], box[2], box[3]), fills);
  }

  /// Union of separately painted elements, not one concatenated even-odd path.
  bool containsReceiver(Offset point) =>
      viewBox.contains(point) &&
      fills.any((fill) => fill._path.contains(point));

  /// Paint an alpha mask to clip destinations after world visibility is drawn.
  /// Curves, subpaths and each element's fill rule go directly to Flutter Path.
  /// Drawing each fill independently also matches SVG edge antialiasing.
  void paint(Canvas canvas, Paint paint) {
    canvas.save();
    canvas.clipRect(viewBox);
    for (final fill in fills) {
      canvas.drawPath(fill._path, paint);
    }
    canvas.restore();
  }
}

class ReceiverFill {
  ReceiverFill._(this._path, this.sourceData, this.fillRule, this.subpathCount,
      this.cubicCount);

  final Path _path;
  final String sourceData;
  final String fillRule;
  final int subpathCount;
  final int cubicCount;

  Path copyPath() => Path.from(_path);
}

class _ExactPathProxy extends PathProxy {
  final path = Path();
  int subpaths = 0;
  int cubics = 0;

  @override
  void moveTo(double x, double y) {
    subpaths++;
    path.moveTo(x, y);
  }

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void cubicTo(
      double x1, double y1, double x2, double y2, double x3, double y3) {
    cubics++;
    path.cubicTo(x1, y1, x2, y2, x3, y3);
  }

  @override
  void close() => path.close();
}

String? _property(XmlElement element, String key) {
  String? result = element.getAttribute(key)?.trim();
  for (final entry in (element.getAttribute('style') ?? '').split(';')) {
    final colon = entry.indexOf(':');
    if (colon >= 0 && entry.substring(0, colon).trim() == key) {
      result = entry.substring(colon + 1).trim();
    }
  }
  return result;
}

double _opacity(String? value) {
  if (value == null) return 1;
  final percent = value.endsWith('%');
  final number =
      double.tryParse(percent ? value.substring(0, value.length - 1) : value);
  if (number == null || !number.isFinite) {
    throw FormatException('Unsupported SVG opacity: $value.');
  }
  return (number / (percent ? 100 : 1)).clamp(0, 1);
}

final _number = RegExp(r'[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?');
List<double> _numbers(String source) {
  if (source
      .replaceAll(_number, '')
      .replaceAll(RegExp(r'[\s,]'), '')
      .isNotEmpty) {
    throw FormatException('Invalid SVG numbers: $source.');
  }
  final values =
      _number.allMatches(source).map((m) => double.parse(m[0]!)).toList();
  if (values.any((value) => !value.isFinite)) {
    throw const FormatException('Non-finite SVG coordinate.');
  }
  return values;
}

class _Affine {
  const _Affine(this.a, this.b, this.c, this.d, this.e, this.f);
  const _Affine.identity() : this(1, 0, 0, 1, 0, 0);
  final double a, b, c, d, e, f;

  _Affine multiply(_Affine other) => _Affine(
        a * other.a + c * other.b,
        b * other.a + d * other.b,
        a * other.c + c * other.d,
        b * other.c + d * other.d,
        a * other.e + c * other.f + e,
        b * other.e + d * other.f + f,
      );

  Float64List get matrix => Float64List.fromList([
        a,
        b,
        0,
        0,
        c,
        d,
        0,
        0,
        0,
        0,
        1,
        0,
        e,
        f,
        0,
        1,
      ]);

  static _Affine parse(String source) {
    var result = const _Affine.identity();
    final function = RegExp(r'([a-zA-Z]+)\s*\(([^)]*)\)');
    if (source.replaceAll(function, '').trim().isNotEmpty) {
      throw FormatException('Invalid SVG transform: $source.');
    }
    for (final match in function.allMatches(source)) {
      final v = _numbers(match[2]!);
      final name = match[1];
      _Affine next;
      if (name == 'matrix' && v.length == 6) {
        next = _Affine(v[0], v[1], v[2], v[3], v[4], v[5]);
      } else if (name == 'translate' && (v.length == 1 || v.length == 2)) {
        next = _Affine(1, 0, 0, 1, v[0], v.length == 2 ? v[1] : 0);
      } else if (name == 'scale' && (v.length == 1 || v.length == 2)) {
        next = _Affine(v[0], 0, 0, v.length == 2 ? v[1] : v[0], 0, 0);
      } else if (name == 'rotate' && (v.length == 1 || v.length == 3)) {
        final angle = v[0] * math.pi / 180;
        next = _Affine(math.cos(angle), math.sin(angle), -math.sin(angle),
            math.cos(angle), 0, 0);
        if (v.length == 3) {
          next = _Affine(1, 0, 0, 1, v[1], v[2])
              .multiply(next)
              .multiply(_Affine(1, 0, 0, 1, -v[1], -v[2]));
        }
      } else if ((name == 'skewX' || name == 'skewY') && v.length == 1) {
        final tangent = math.tan(v[0] * math.pi / 180);
        next = _Affine(1, name == 'skewY' ? tangent : 0,
            name == 'skewX' ? tangent : 0, 1, 0, 0);
      } else {
        throw FormatException('Unsupported SVG transform: ${match[0]}.');
      }
      result = result.multiply(next);
    }
    if (result.matrix.any((value) => !value.isFinite)) {
      throw const FormatException('Non-finite SVG transform.');
    }
    return result;
  }
}
