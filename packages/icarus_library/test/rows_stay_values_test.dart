import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

Future<LiveElement> storedLine(MemoryStorage disk) async {
  final store = await openStore(MemoryEngine(disk));
  final page = pageOf(await store.readPage(strategyId, 'page-a'));
  await store.close();
  return elementOn(page, 'line') as LiveElement;
}

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = await seededClean();
  });

  test(
    'what a read hands out offers no way to change the stored row',
    () async {
      final disk = MemoryStorage(seeded);
      final line = await storedLine(disk);
      final before = jsonEncode(line.toJson());
      final data = line.payload.data;
      final points = data['points'];
      final point = (points! as JsonList)[0];

      expect(data, isNot(isA<Map<Object?, Object?>>()));
      expect(points, isA<JsonList>());
      expect(points, isNot(isA<List<Object?>>()));
      expect(point, isA<JsonObject>());
      expect(point, isNot(isA<Map<Object?, Object?>>()));
      expect(line.unknownFields, isNot(isA<Map<Object?, Object?>>()));
      expect(line.toJson()['payload'], isA<Map<String, Object?>>());
      expect(
        (line.toJson()['payload']! as Map<String, Object?>)['data'],
        isA<JsonObject>(),
      );

      data.toMap()['points'] = 'changed';
      final shallow = data.toMap();
      shallow.clear();
      final plain = data.toJson();
      ((plain['points']! as List<Object?>)[0]! as Map<String, Object?>)['dx'] =
          -1;
      (plain['points']! as List<Object?>).clear();
      line.toJson()['payload'] = 'changed';
      final payloadPlain = line.payload.toPlainJson();
      (payloadPlain['data']! as Map<String, Object?>).clear();
      final listed = (points as JsonList).toList()..clear();

      expect(listed, isEmpty);
      expect(jsonEncode(line.toJson()), before);
      expect(
        (await storedLine(disk)).toJson().toString(),
        line.toJson().toString(),
      );
      expect(jsonEncode((await storedLine(disk)).toJson()), before);
    },
  );

  test('a row made from a caller\'s map keeps a copy of it', () {
    final points = <Object?>[
      <String, Object?>{'dx': 1, 'dy': 2},
    ];
    final data = <String, Object?>{
      'id': 'mine',
      'elementType': 'drawing',
      'points': points,
    };
    final payload = ElementPayload(
      kind: ElementKind.drawing,
      payloadVersion: 1,
      data: data,
    );
    data['id'] = 'changed';
    (points[0]! as Map<String, Object?>)['dx'] = 99;
    points.add(<String, Object?>{'dx': 3, 'dy': 4});
    expect(payload.data.toJson(), {
      'id': 'mine',
      'elementType': 'drawing',
      'points': [
        {'dx': 1, 'dy': 2},
      ],
    });
  });

  test(
    'an unreadable row hands out its stored value as a read-only view',
    () async {
      final disk = MemoryStorage(await seededContents());
      final store = await openStore(MemoryEngine(disk));
      final page = pageOf(await store.readPage(strategyId, 'page-a'));
      final smoke = elementOn(page, 'smoke') as UnreadableElement;
      expect(smoke.stored, isA<JsonObject>());
      expect(smoke.stored, isNot(isA<Map<Object?, Object?>>()));
      expect(smoke.toJson(), isA<JsonObject>());
    },
  );
}
