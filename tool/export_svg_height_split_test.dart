// First-pass SVG/height preview. Does not open Hive or replace app assets.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

const _revision = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
const _fixture = 'E:/IcarusWorldAudit/2026-09-06/compact-prototype/'
    'native-walking-fixtures-v1/split/walking-144hz.json';

class _ConePaint extends CustomPainter {
  _ConePaint(this.polygons, this.receiver);
  final List<List<Offset>> polygons;
  final WorldReceiverMask receiver;

  @override
  void paint(Canvas canvas, Size size) {
    final mask = receiver.fills
        .map((f) => f.copyPath())
        .reduce((a, b) => Path.combine(PathOperation.union, a, b));
    canvas.save();
    canvas.clipPath(mask);
    for (final points in polygons) {
      if (points.length < 3) continue;
      canvas.drawPath(Path()..addPolygon(points, true),
          Paint()..color = Colors.white.withValues(alpha: .24));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ConePaint oldDelegate) => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('render Split using authored wall footprints and height metadata',
      (tester) async {
    final result = await tester.runAsync(() async {
      final input = Platform.environment['ICARUS_SVG_HEIGHT_INPUT'] ??
          '$_revision/split-svg-semantic-prototype-v2';
      final out = Directory(Platform.environment['ICARUS_SVG_HEIGHT_OUTPUT'] ??
          '$_revision/split-svg-height-preview-v1');
      if (out.existsSync())
        throw StateError('Preserve existing preview output.');
      out.createSync(recursive: true);
      final fixture = jsonDecode(await File(_fixture).readAsString()) as Map;
      final frame = fixture['frames'][0] as Map;
      final reviewFile = File('$input/review-poses.json');
      final reviewCases = reviewFile.existsSync()
          ? (jsonDecode(await reviewFile.readAsString())['cases'] as List)
          : const [];
      final casePattern =
          Platform.environment['ICARUS_SVG_HEIGHT_CASE_PATTERN'];
      final caseFilter = casePattern == null ? null : RegExp(casePattern);
      final records = <Map<String, dynamic>>[];
      final icons = <ui.Image>[];
      for (var i = 0; i < 10; i++) {
        final bytes = await rootBundle
            .load(AgentData.agents[AgentType.values[i]]!.iconPath);
        final codec =
            await ui.instantiateImageCodec(bytes.buffer.asUint8List());
        icons.add((await codec.getNextFrame()).image);
        codec.dispose();
      }
      await tester.binding.setSurfaceSize(const Size(500, 500));
      for (final side in ['attack', 'defense']) {
        final data =
            jsonDecode(await File('$input/split-$side.json').readAsString())
                as Map<String, dynamic>;
        final model = SvgHeightVisibility.fromJson(data);
        final svg = await File(
                'assets/maps/split_map${side == 'defense' ? '_defense' : ''}.svg')
            .readAsString();
        final receiver = WorldReceiverMask.parse(svg);
        for (final review in <Map?>[
          null,
          ...reviewCases
              .where((c) =>
                  c['side'] == side &&
                  (caseFilter == null ||
                      caseFilter.hasMatch(c['id'] as String)))
              .cast<Map>()
        ]) {
          final positions = <Offset>[];
          final polygons = <List<Offset>>[];
          final poseRecords = <Map<String, dynamic>>[];
          for (var i = 0; i < (review == null ? 10 : 1); i++) {
            final p = frame['positionsSvg'][i] as List;
            final q = frame['poses'][i] as List;
            // Each side uses its literal artwork. Split's defense artwork has
            // a recorded sub-unit translation relative to canonical reflection.
            final origin = review != null
                ? Offset((review['originSvg'][0] as num).toDouble(),
                    (review['originSvg'][1] as num).toDouble())
                : side == 'attack'
                    ? Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())
                    : Offset(467 - (p[0] as num).toDouble() - .8238,
                        473 - (p[1] as num).toDouble());
            final direction = review != null
                ? (review['directionRadians'] as num).toDouble()
                : math.atan2(
                        -(q[4] as num).toDouble(), (q[3] as num).toDouble()) +
                    (side == 'defense' ? math.pi : 0);
            final watch = Stopwatch()..start();
            final cone = model.cone(
                origin: origin,
                directionRadians: direction,
                range: review != null
                    ? (review['rangeSvg'] as num).toDouble()
                    : (q[5] as num).toDouble() * 3.9096202760784,
                apertureRadians: review != null
                    ? (review['apertureRadians'] as num).toDouble()
                    : (q[6] as num).toDouble(),
                cameraHeightMeters: 1.75,
                supportId: review?['supportId'] as String?);
            watch.stop();
            positions.add(origin);
            polygons.add(cone.polygon);
            poseRecords.add({
              'agentIndex': i,
              'originSvg': [origin.dx, origin.dy],
              'eyeHeightAboveLocalFloorMeters': cone.eyeHeightAboveFloorMeters,
              'queryMicroseconds': watch.elapsedMicroseconds,
              'supportId': review?['supportId'],
              'supportPolicy': review?['description'] ??
                  'Standing on connected local floor; no inferred box or roof.'
            });
          }
          final key = GlobalKey();
          await tester.pumpWidget(Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                  alignment: Alignment.topLeft,
                  child: RepaintBoundary(
                      key: key,
                      child: SizedBox(
                          width: receiver.viewBox.width,
                          height: receiver.viewBox.height,
                          child: ColoredBox(
                              color: Settings.tacticalVioletTheme.background,
                              child: Stack(children: [
                                Positioned.fill(
                                    child: SvgPicture.string(svg,
                                        fit: BoxFit.fill)),
                                Positioned.fill(
                                    child: CustomPaint(
                                        painter:
                                            _ConePaint(polygons, receiver))),
                                for (var i = 0; i < positions.length; i++)
                                  Positioned(
                                      left: positions[i].dx -
                                          (review == null ? 9 : 1.2),
                                      top: positions[i].dy -
                                          (review == null ? 9 : 1.2),
                                      width: review == null ? 18 : 2.4,
                                      height: review == null ? 18 : 2.4,
                                      child: DecoratedBox(
                                          decoration: BoxDecoration(
                                              color: Settings.allyBGColor,
                                              shape: review == null
                                                  ? BoxShape.rectangle
                                                  : BoxShape.circle,
                                              border: Border.all(
                                                  color:
                                                      Settings.allyOutlineColor,
                                                  width: .5)),
                                          child: review == null
                                              ? RawImage(image: icons[i])
                                              : null)),
                              ])))))));
          await tester.pumpAndSettle();
          for (final scale in [2.25, 8.0]) {
            final image = await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: scale);
            final bytes =
                (await image.toByteData(format: ui.ImageByteFormat.png))!
                    .buffer
                    .asUint8List();
            image.dispose();
            final path =
                '${out.path}/split-$side${review == null ? '' : '-${review['id']}'}-${scale == 8 ? 'native8x' : 'full'}.png';
            await File(path).writeAsBytes(bytes);
            records.add({
              'side': side,
              'reviewCase': review,
              'image': path,
              'pixelRatio': scale,
              'poses': poseRecords
            });
          }
          await tester.pumpWidget(const SizedBox());
        }
      }
      await File('${out.path}/manifest.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert({
        'input': input,
        'fixture': _fixture,
        'records': records,
        'scope':
            'First SVG-height engine preview on actual artwork. Unknown height associations remain explicit in input. No production promotion or gameplay certification.'
      }));
      await tester.binding.setSurfaceSize(null);
      for (final icon in icons) {
        icon.dispose();
      }
      return true;
    });
    expect(result, isTrue);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
