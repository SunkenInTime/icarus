import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

const int _testColorAdapterTypeId = 220;

class _TestColorAdapter extends TypeAdapter<Color> {
  @override
  final typeId = _testColorAdapterTypeId;

  @override
  Color read(BinaryReader reader) {
    return Color((reader.read() as num).toInt());
  }

  @override
  void write(BinaryWriter writer, Color obj) {
    writer.write(obj.toARGB32());
  }
}

void _ensureAdaptersRegistered() {
  if (!Hive.isAdapterRegistered(20)) {
    registerIcarusAdapters(Hive);
  }
  if (!Hive.isAdapterRegistered(_testColorAdapterTypeId)) {
    Hive.registerAdapter(_TestColorAdapter());
  }
}

Map<int, dynamic> _readAdapterFields(
  void Function(BinaryWriterImpl writer) writeObject,
) {
  _ensureAdaptersRegistered();
  final writer = BinaryWriterImpl(Hive);
  writeObject(writer);
  final reader = BinaryReaderImpl(Uint8List.fromList(writer.toBytes()), Hive);
  final numOfFields = reader.readByte();
  return <int, dynamic>{
    for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
  };
}

BinaryReaderImpl _legacyFieldReader(Map<int, dynamic> fields) {
  _ensureAdaptersRegistered();
  final writer = BinaryWriterImpl(Hive)..writeByte(fields.length);
  for (final entry in fields.entries) {
    writer
      ..writeByte(entry.key)
      ..write(entry.value);
  }
  return BinaryReaderImpl(Uint8List.fromList(writer.toBytes()), Hive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JSON color persistence', () {
    test('strategy page exports user-editable colors as ints', () {
      final page = StrategyPage(
        id: 'page-1',
        name: 'Page 1',
        drawingData: [
          Line(
            id: 'line-1',
            lineStart: const Offset(1, 2),
            lineEnd: const Offset(3, 4),
            color: const Color(0xFFAA5500),
            boundingBox: BoundingBox(
              min: const Offset(1, 2),
              max: const Offset(3, 4),
            ),
            isDotted: false,
            hasArrow: true,
          ),
        ],
        agentData: const [],
        abilityData: const [],
        textData: [
          PlacedText(
            id: 'text-1',
            position: const Offset(5, 6),
            tagColorValue: 0xFF22C55E,
          )..text = 'Tagged text',
        ],
        imageData: [
          PlacedImage(
            id: 'image-1',
            position: const Offset(7, 8),
            aspectRatio: 1.5,
            scale: 200,
            fileExtension: '.png',
            tagColorValue: 0xFF3B82F6,
          ),
        ],
        utilityData: [
          PlacedUtility(
            id: 'utility-1',
            position: const Offset(9, 10),
            type: UtilityType.customCircle,
            customDiameter: 12,
            customColorValue: 0xFFEF4444,
            customOpacityPercent: 35,
          ),
        ],
        sortIndex: 0,
        isAttack: true,
        settings: StrategySettings(),
      );

      final payload = page.toJson('strategy-1');
      final drawingJson = (payload['drawingData'] as List<dynamic>).single
          as Map<String, dynamic>;
      final textJson =
          (payload['textData'] as List<dynamic>).single as Map<String, dynamic>;
      final imageJson = (payload['imageData'] as List<dynamic>).single
          as Map<String, dynamic>;
      final utilityJson = (payload['utilityData'] as List<dynamic>).single
          as Map<String, dynamic>;

      expect(drawingJson['colorValue'], 0xFFAA5500);
      expect(drawingJson.containsKey('color'), isFalse);
      expect(textJson['tagColorValue'], 0xFF22C55E);
      expect(imageJson['tagColorValue'], 0xFF3B82F6);
      expect(utilityJson['customColorValue'], 0xFFEF4444);
    });

    test('legacy drawing color strings still deserialize', () {
      final decoded = DrawingProvider.fromJson(jsonEncode([
        {
          'type': 'lineDrawing',
          'id': 'line-legacy',
          'color': '#FF22C55E',
          'isDotted': false,
          'hasArrow': false,
          'lineStart': {'dx': 1.0, 'dy': 2.0},
          'lineEnd': {'dx': 3.0, 'dy': 4.0},
        },
        {
          'type': 'freeDrawing',
          'id': 'free-legacy',
          'color': '#FFEF4444',
          'isDotted': false,
          'hasArrow': false,
          'listOfPoints': [
            {'dx': 5.0, 'dy': 6.0},
            {'dx': 7.0, 'dy': 8.0},
          ],
        },
      ]));

      expect((decoded[0] as Line).colorValue, 0xFF22C55E);
      expect((decoded[1] as FreeDrawing).colorValue, 0xFFEF4444);
    });
  });

  group('Hive color persistence', () {
    test('drawing adapters write integer color fields', () {
      final freeDrawingFields = _readAdapterFields(
        (writer) => FreeDrawingAdapter().write(
          writer,
          FreeDrawing(
            id: 'free-1',
            listOfPoints: const [Offset(1, 2), Offset(3, 4)],
            color: const Color(0xFF22C55E),
            isDotted: false,
            hasArrow: false,
          ),
        ),
      );
      final lineFields = _readAdapterFields(
        (writer) => LineAdapter().write(
          writer,
          Line(
            id: 'line-1',
            lineStart: const Offset(1, 2),
            lineEnd: const Offset(3, 4),
            color: const Color(0xFF3B82F6),
            boundingBox: BoundingBox(
              min: const Offset(1, 2),
              max: const Offset(3, 4),
            ),
            isDotted: false,
            hasArrow: true,
          ),
        ),
      );
      final rectangleFields = _readAdapterFields(
        (writer) => RectangleDrawingAdapter().write(
          writer,
          RectangleDrawing(
            id: 'rect-1',
            start: const Offset(1, 2),
            end: const Offset(3, 4),
            color: const Color(0xFFF59E0B),
            boundingBox: BoundingBox(
              min: const Offset(1, 2),
              max: const Offset(3, 4),
            ),
            isDotted: true,
            hasArrow: false,
          ),
        ),
      );
      final ellipseFields = _readAdapterFields(
        (writer) => EllipseDrawingAdapter().write(
          writer,
          EllipseDrawing(
            id: 'ellipse-1',
            start: const Offset(1, 2),
            end: const Offset(3, 4),
            color: const Color(0xFFA855F7),
            boundingBox: BoundingBox(
              min: const Offset(1, 2),
              max: const Offset(3, 4),
            ),
            isDotted: true,
            hasArrow: false,
          ),
        ),
      );

      expect(freeDrawingFields[2], 0xFF22C55E);
      expect(lineFields[2], 0xFF3B82F6);
      expect(rectangleFields[2], 0xFFF59E0B);
      expect(ellipseFields[2], 0xFFA855F7);

      expect(freeDrawingFields.values.whereType<Color>(), isEmpty);
      expect(lineFields.values.whereType<Color>(), isEmpty);
      expect(rectangleFields.values.whereType<Color>(), isEmpty);
      expect(ellipseFields.values.whereType<Color>(), isEmpty);
    });

    test('drawing adapters still read legacy Hive Color payloads', () {
      final restoredLine = LineAdapter().read(
        _legacyFieldReader({
          0: const Offset(1, 2),
          1: const Offset(3, 4),
          2: const Color(0xFFEF4444),
          3: true,
          4: false,
          5: 'legacy-line',
          6: BoundingBox(
            min: const Offset(1, 2),
            max: const Offset(3, 4),
          ),
          7: false,
          8: TraversalSpeedProfile.walking,
          9: 5.0,
        }),
      );

      expect(restoredLine.colorValue, 0xFFEF4444);
      expect(restoredLine.color, const Color(0xFFEF4444));
    });

    test('placed model adapters continue writing integer color fields', () {
      final textFields = _readAdapterFields(
        (writer) => PlacedTextAdapter().write(
          writer,
          PlacedText(
            id: 'text-1',
            position: const Offset(1, 2),
            tagColorValue: 0xFF22C55E,
          )..text = 'hello',
        ),
      );
      final imageFields = _readAdapterFields(
        (writer) => PlacedImageAdapter().write(
          writer,
          PlacedImage(
            id: 'image-1',
            position: const Offset(3, 4),
            aspectRatio: 1.5,
            scale: 200,
            fileExtension: '.png',
            tagColorValue: 0xFF3B82F6,
          ),
        ),
      );
      final utilityFields = _readAdapterFields(
        (writer) => PlacedUtilityAdapter().write(
          writer,
          PlacedUtility(
            id: 'utility-1',
            position: const Offset(5, 6),
            type: UtilityType.customRectangle,
            customWidth: 4,
            customLength: 8,
            customColorValue: 0xFFF59E0B,
            customOpacityPercent: 45,
          ),
        ),
      );
      final circleAgentFields = _readAdapterFields(
        (writer) => PlacedCircleAgentAdapter().write(
          writer,
          PlacedCircleAgent(
            id: 'circle-agent-1',
            type: AgentType.jett,
            position: const Offset(7, 8),
            diameterMeters: 12,
            colorValue: 0xFFA855F7,
            opacityPercent: 60,
          ),
        ),
      );

      expect(textFields[5], 0xFF22C55E);
      expect(imageFields[9], 0xFF3B82F6);
      expect(utilityFields[11], 0xFFF59E0B);
      expect(circleAgentFields[1], 0xFFA855F7);
      expect(textFields.values.whereType<Color>(), isEmpty);
      expect(imageFields.values.whereType<Color>(), isEmpty);
      expect(utilityFields.values.whereType<Color>(), isEmpty);
      expect(circleAgentFields.values.whereType<Color>(), isEmpty);
    });
  });
}
