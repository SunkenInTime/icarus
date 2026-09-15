import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:xml/xml.dart';

import 'world_receiver_mask.dart';

String _svg(String content, {String box = '0 0 100 100'}) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="$box">$content</svg>';
const _outer = 'M0 0H100V100H0Z';
const _innerSame = 'M25 25H75V75H25Z';
const _innerReverse = 'M25 25V75H75V25Z';
const _white = ui.Color(0xffffffff);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Flutter tests otherwise use Ahem, which turns comparison labels into bars.
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (font.existsSync()) {
      await (FontLoader('ReceiverAudit')
            ..addFont(
                Future.value(ByteData.sublistView(font.readAsBytesSync()))))
          .load();
    }
  });

  test('preserves holes under each individual path fill rule', () {
    for (final (rule, inner, center) in [
      ('evenodd', _innerSame, false),
      ('nonzero', _innerSame, true),
      ('nonzero', _innerReverse, false),
    ]) {
      final mask = WorldReceiverMask.parse(_svg(
        '<path fill="#271406" fill-rule="$rule" d="$_outer $inner"/>',
      ));
      expect(mask.fills.single.subpathCount, 2);
      expect(mask.fills.single.fillRule, rule);
      expect(mask.containsReceiver(const ui.Offset(50, 50)), center);
      expect(mask.containsReceiver(const ui.Offset(10, 50)), isTrue);
      expect(mask.containsReceiver(const ui.Offset(-1, 50)), isFalse);
    }
  });

  test('unions painted elements without cancelling overlaps or losing islands',
      () {
    final mask = WorldReceiverMask.parse(_svg('''
      <path fill="#271406" fill-rule="evenodd" d="M0 0H40V40H0Z"/>
      <path fill="#271406" fill-rule="evenodd" d="M20 0H60V40H20Z"/>
      <path fill="#271406" d="M80 70H90V90H80Z"/>
      <defs><path fill="#271406" d="$_outer"/></defs>
      <path display="none" fill="#271406" d="$_outer"/>
    '''));
    expect(mask.fills, hasLength(3));
    expect(mask.containsReceiver(const ui.Offset(30, 20)), isTrue);
    expect(mask.containsReceiver(const ui.Offset(85, 80)), isTrue);
    expect(mask.containsReceiver(const ui.Offset(70, 60)), isFalse);
  });

  test('keeps cubic commands and implicit subpath closure', () {
    const d = 'M0 50C0 0 100 0 100 50C100 100 0 100 0 50 '
        'M40 40H60V60H40';
    final mask = WorldReceiverMask.parse(_svg(
      '<path fill="#271406" fill-rule="evenodd" d="$d"/>',
    ));
    expect(mask.fills.single.sourceData, d);
    expect(mask.fills.single.cubicCount, 2);
    expect(mask.fills.single.subpathCount, 2);
    expect(mask.containsReceiver(const ui.Offset(50, 50)), isFalse);
    expect(mask.containsReceiver(const ui.Offset(20, 50)), isTrue);
    expect(mask.containsReceiver(const ui.Offset(1, 1)), isFalse);
  });

  test('inherits fill and winding and applies nested affine transforms', () {
    final mask = WorldReceiverMask.parse(_svg('''
      <g fill="#271406" fill-rule="evenodd" transform="translate(20 10)">
        <path transform="scale(.5)" d="$_outer $_innerSame"/>
      </g>
    '''));
    expect(mask.fills.single.fillRule, 'evenodd');
    expect(mask.containsReceiver(const ui.Offset(25, 20)), isTrue);
    expect(mask.containsReceiver(const ui.Offset(45, 35)), isFalse);
    expect(mask.containsReceiver(const ui.Offset(10, 10)), isFalse);
    final rotated = WorldReceiverMask.parse(_svg('''
      <path fill="#271406" transform="rotate(90 50 50)"
        d="M10 10H20V30H10Z"/>
    '''));
    expect(rotated.containsReceiver(const ui.Offset(80, 15)), isTrue);
  });

  test('fails explicitly on unsupported receiver rendering dependencies', () {
    for (final source in [
      _svg('<path fill="#271406" clip-path="url(#x)" d="$_outer"/>'),
      _svg('<style>path { fill: #271406; }</style><path d="$_outer"/>'),
      _svg('<use href="#x"/>'),
      _svg('<rect fill="#271406" width="20" height="20"/>'),
      _svg('<path fill="#271406" fill-rule="unknown" d="$_outer"/>'),
      _svg('<path fill="#271406" d="M0 50A50 50 0 0 1 100 50Z"/>'),
    ]) {
      expect(() => WorldReceiverMask.parse(source), throwsFormatException);
    }
  });

  test(
      'positive artwork opacity retains receivers while transparent paint does not',
      () {
    final mask = WorldReceiverMask.parse(_svg('''
      <path fill="#271406" fill-opacity="0.9" d="M0 0H20V20H0Z"/>
      <g opacity="0"><path fill="#271406" d="M40 0H60V20H40Z"/></g>
      <g fill-opacity="0">
        <path fill="#271406" d="M60 0H80V20H60Z"/>
        <path fill="#271406" fill-opacity="10%" d="M80 0H100V20H80Z"/>
      </g>
    '''));
    expect(mask.fills, hasLength(2));
    expect(mask.containsReceiver(const ui.Offset(10, 10)), isTrue);
    expect(mask.containsReceiver(const ui.Offset(50, 10)), isFalse);
    expect(mask.containsReceiver(const ui.Offset(70, 10)), isFalse);
    expect(mask.containsReceiver(const ui.Offset(90, 10)), isTrue);
  });

  test('a sightline can leave and re-enter the receiver domain', () {
    final mask = WorldReceiverMask.parse(_svg('''
      <path fill="#271406" d="M0 0H20V100H0Z M80 0H100V100H80Z"/>
    '''));
    const observer = ui.Offset(10, 50);
    const target = ui.Offset(90, 50);
    expect(mask.containsReceiver(observer), isTrue);
    expect(mask.containsReceiver((observer + target) / 2), isFalse);
    expect(mask.containsReceiver(target), isTrue);
    // This function deliberately asks the independent scene query about the
    // entire segment. Neither a mask exit nor re-entry creates a wall.
    bool visible(double? firstWorldHitDistance) =>
        mask.containsReceiver(target) &&
        (firstWorldHitDistance == null ||
            firstWorldHitDistance >= (target - observer).distance);
    expect(visible(null), isTrue);
    // A real wall in the unpainted gap still occludes the painted target.
    expect(visible(40), isFalse);
  });

  test('retains all current base paths for all 26 actual side assets', () {
    const expected = {
      'abyss': 3,
      'lotus': 3,
      'pearl': 4,
      'haven': 2,
      'fracture': 2
    };
    for (final map in MapValue.values) {
      for (final suffix in ['', '_defense']) {
        final source =
            File('assets/maps/${map.name}_map$suffix.svg').readAsStringSync();
        final mask = WorldReceiverMask.parse(source);
        final paths = _sourceBasePaths(source);
        expect(mask.fills, hasLength(expected[map.name] ?? 1),
            reason: '${map.name}$suffix');
        expect(mask.fills.map((fill) => fill.sourceData),
            paths.map((path) => path.getAttribute('d')),
            reason: '${map.name}$suffix');
        expect(mask.fills.map((fill) => fill.fillRule),
            paths.map((path) => path.getAttribute('fill-rule') ?? 'nonzero'));
      }
    }
  });

  test('uses the defense asset including its real frame offset', () {
    WorldReceiverMask load(String suffix) => WorldReceiverMask.parse(
        File('assets/maps/split_map$suffix.svg').readAsStringSync());
    final attack = load('');
    final defense = load('_defense');
    final a = attack.fills.single.copyPath().getBounds();
    final d = defense.fills.single.copyPath().getBounds();
    expect(attack.viewBox, defense.viewBox);
    final reflectedDefenseLeft = defense.viewBox.width - d.right;
    expect(reflectedDefenseLeft - a.left, closeTo(.824, .001));
  });

  test('matches Flutter SVG fill rendering on all 26 map-side masks', () async {
    const outputPath = String.fromEnvironment('RECEIVER_MASK_AUDIT_DIR',
        defaultValue: 'build/receiver_mask_audit');
    final output = Directory(outputPath)..createSync(recursive: true);
    final records = <Map<String, Object>>[];
    for (final map in MapValue.values.map((value) => value.name)) {
      for (final suffix in ['', '_defense']) {
        final asset = 'assets/maps/${map}_map$suffix.svg';
        final source = File(asset).readAsStringSync();
        final mask = WorldReceiverMask.parse(source);
        final referenceSource = _referenceSvg(source);
        final picture =
            await vg.loadPicture(SvgStringLoader(referenceSource), null);
        final width = (mask.viewBox.width * 2).ceil();
        final height = (mask.viewBox.height * 2).ceil();
        final reference = await _raster(width, height, (canvas) {
          canvas.scale(2);
          canvas.drawPicture(picture.picture);
        });
        final actual = await _raster(width, height, (canvas) {
          canvas.scale(2);
          canvas.translate(-mask.viewBox.left, -mask.viewBox.top);
          mask.paint(canvas, ui.Paint()..color = _white);
        });
        final referenceBytes =
            (await reference.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final actualBytes =
            (await actual.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        var differences = 0, maximum = 0, interiorDisagreements = 0, opaque = 0;
        final diff = Uint8List(width * height * 4);
        for (var i = 3; i < referenceBytes.lengthInBytes; i += 4) {
          final r = referenceBytes.getUint8(i), a = actualBytes.getUint8(i);
          final delta = (r - a).abs();
          if (delta > 0) differences++;
          maximum = math.max(maximum, delta);
          if ((r == 0 && a == 255) || (a == 0 && r == 255))
            interiorDisagreements++;
          if (r == 255) opaque++;
          diff[i - 3] = delta;
          diff[i] = 255;
        }
        final id = '$map${suffix.isEmpty ? '_attack' : suffix}';
        records.add({
          'asset': asset,
          'basePathCount': mask.fills.length,
          'subpathCounts': mask.fills.map((f) => f.subpathCount).toList(),
          'cubicCounts': mask.fills.map((f) => f.cubicCount).toList(),
          'fillRules': mask.fills.map((f) => f.fillRule).toList(),
          'width': width,
          'height': height,
          'opaqueReferencePixels': opaque,
          'differingAlphaPixels': differences,
          'maximumAlphaDifference': maximum,
          'fullyOpaqueVersusEmptyPixels': interiorDisagreements,
          'comparison': '$id.png',
        });
        await _saveComparison(
            reference,
            actual,
            diff,
            '$map ${suffix.isEmpty ? 'attack' : 'defense'}',
            File('${output.path}/$id.png'));
        File('${output.path}/$id-reference.svg')
            .writeAsStringSync(referenceSource);
        picture.picture.dispose();
        reference.dispose();
        actual.dispose();
      }
    }
    File('${output.path}/comparison.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'scope':
            'Isolated receiver mask, not application or gameplay verification',
        'reference':
            'Flutter SVG renderer, all original #271406 paths, fill only',
        'candidate':
            'Unflattened Flutter Paths, individual fill rules, union by painting',
        'scale': 2,
        'results': records,
      }),
    );
    for (final record in records) {
      expect(record['fullyOpaqueVersusEmptyPixels'], 0,
          reason: '${record['asset']}');
      expect(record['maximumAlphaDifference'], 0, reason: '${record['asset']}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

// Independent extraction for the renderer comparison. These current sources
// have explicit base fills and no inherited transforms/styles on those paths.
// Assert that contract instead of reusing the receiver parser's traversal.
List<XmlElement> _sourceBasePaths(String source) {
  final root = XmlDocument.parse(source).rootElement;
  final paths = root.descendants
      .whereType<XmlElement>()
      .where((element) =>
          element.name.local == 'path' &&
          element.getAttribute('fill')?.toLowerCase() == '#271406')
      .toList();
  for (final path in paths) {
    for (XmlNode? node = path; node is XmlElement; node = node.parent) {
      expect(['svg', 'g', 'path'], contains(node.name.local));
      for (final key in [
        'transform',
        'style',
        'clip-path',
        'mask',
        'opacity',
      ]) {
        expect(node.getAttribute(key), isNull,
            reason: 'Independent reference needs ancestor $key support');
      }
      final fillOpacity = node.getAttribute('fill-opacity');
      if (fillOpacity != null) {
        expect(double.parse(fillOpacity), greaterThan(0),
            reason: 'Current translucent base paths still paint receivers');
      }
    }
  }
  return paths;
}

String _referenceSvg(String source) {
  final original = XmlDocument.parse(source).rootElement;
  final paths = _sourceBasePaths(source);
  final root = XmlElement(XmlName('svg'), [
    XmlAttribute(XmlName('xmlns'), 'http://www.w3.org/2000/svg'),
    XmlAttribute(XmlName('viewBox'), original.getAttribute('viewBox')!),
    XmlAttribute(XmlName('width'), original.getAttribute('width')!),
    XmlAttribute(XmlName('height'), original.getAttribute('height')!),
  ], [
    for (final path in paths)
      XmlElement(XmlName('path'), [
        XmlAttribute(XmlName('fill'), '#ffffff'),
        XmlAttribute(XmlName('d'), path.getAttribute('d')!),
        if (path.getAttribute('fill-rule') case final String rule)
          XmlAttribute(XmlName('fill-rule'), rule),
      ]),
  ]);
  return root.toXmlString();
}

Future<ui.Image> _raster(
    int width, int height, void Function(ui.Canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(ui.Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  return image;
}

Future<void> _saveComparison(ui.Image reference, ui.Image actual,
    Uint8List diff, String title, File file) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(diff);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: reference.width,
    height: reference.height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final difference = (await codec.getNextFrame()).image;
  const labelHeight = 40;
  final comparison = await _raster(
      reference.width * 3, reference.height + labelHeight, (canvas) {
    canvas.drawPaint(ui.Paint()..color = const ui.Color(0xff171717));
    for (final (index, image, label) in [
      (0, reference, '$title | Flutter SVG fill'),
      (1, actual, 'Receiver mask | original curves'),
      (2, difference, 'Absolute alpha difference | red'),
    ]) {
      final x = index * reference.width.toDouble();
      canvas.drawImage(image, ui.Offset(x, labelHeight.toDouble()), ui.Paint());
      final builder = ui.ParagraphBuilder(
          ui.ParagraphStyle(fontSize: 20, fontFamily: 'ReceiverAudit'))
        ..pushStyle(ui.TextStyle(color: _white))
        ..addText(label);
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: reference.width - 16));
      canvas.drawParagraph(paragraph, ui.Offset(x + 8, 8));
      paragraph.dispose();
    }
  });
  final png = (await comparison.toByteData(format: ui.ImageByteFormat.png))!;
  file.writeAsBytesSync(png.buffer.asUint8List());
  comparison.dispose();
  difference.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
}
