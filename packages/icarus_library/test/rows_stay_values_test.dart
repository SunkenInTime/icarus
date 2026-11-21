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
      expect(line.toJsonView()['payload'], isA<Map<String, Object?>>());
      expect(
        (line.toJsonView()['payload']! as Map<String, Object?>)['data'],
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
      final payloadPlain = line.payload.toJson();
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
      expect(smoke.toJsonView(), isA<JsonObject>());
      expect(smoke.toJson(), isA<Map<String, Object?>>());
    },
  );

  test(
    'a merge base taken from a stored drawing cannot change it, in the cache or on disk',
    () async {
      final disk = MemoryStorage(seeded);
      final store = await openStore(MemoryEngine(disk));
      final line =
          elementOn(pageOf(await store.readPage(strategyId, 'page-a')), 'line')
              as LiveElement;
      final before = jsonEncode(line.toJson());
      final stored = disk.contents[sampleArea]![elementName('page-a', 'line')];
      final merge = FieldMerge(
        fields: ['points'],
        base: {'points': line.payload.data['points']},
      );
      if (merge.base?['points'] case final List<Object?> backing) {
        backing.clear();
      }
      final plainBase = merge.toJson()['base']! as List<Object?>;
      final baseEntry = plainBase.single! as Map<String, Object?>;
      final basePoints = baseEntry['value']! as List<Object?>;
      final firstPoint = basePoints.first! as Map<String, Object?>;
      firstPoint['dx'] = -1;
      final opPlain = ElementPatchOp(
        opId: 'with-base',
        elementPublicId: 'line',
        expectedElementRevision: 1,
        payload: line.payload,
        merge: merge,
      ).toJson();
      final opPayload = opPlain['payload']! as Map<String, Object?>;
      final opData = opPayload['data']! as Map<String, Object?>;
      (opData['points']! as List<Object?>).clear();
      savedValue(
        await store.commit(
          strategyId,
          const ElementReorderOp(
            opId: 'reorder-line',
            elementPublicId: 'line',
            pagePublicId: 'page-a',
            sortIndex: 7,
            expectedElementRevision: 1,
          ),
        ),
      );
      final again =
          elementOn(pageOf(await store.readPage(strategyId, 'page-a')), 'line')
              as LiveElement;
      expect(merge.base, isA<JsonObject>());
      expect(merge.base!['points'], isA<JsonList>());
      expect(again.payload.data.toJson(), line.payload.data.toJson());
      expect(jsonEncode(line.toJson()), before);
      await store.close();
      final reopened = await openStore(MemoryEngine(disk));
      final onDisk =
          elementOn(
                pageOf(await reopened.readPage(strategyId, 'page-a')),
                'line',
              )
              as LiveElement;
      expect(
        jsonEncode(onDisk.payload.data.toJson()),
        jsonEncode(((jsonDecode(stored!) as Map)['payload'] as Map)['data']),
      );
    },
  );

  test('the JSON an op or a row hands out is plain all the way down', () async {
    final line = await storedLine(MemoryStorage(seeded));
    bool plain(Object? json) => switch (json) {
      final Map<String, Object?> map => map.values.every(plain),
      final List<Object?> list => list.every(plain),
      JsonObject() || JsonList() => false,
      _ => true,
    };
    final ops = [
      ElementAddOp(
        opId: 'add',
        elementPublicId: 'copy',
        pagePublicId: 'page-a',
        payload: line.payload,
        sortIndex: 0,
      ),
      ElementPatchOp(
        opId: 'patch',
        elementPublicId: 'line',
        expectedElementRevision: 1,
        payload: line.payload,
        merge: FieldMerge(
          fields: ['points'],
          base: {'points': line.payload.data['points']},
        ),
      ),
    ];
    for (final op in ops) {
      expect(plain(op.toJson()), isTrue, reason: op.opId);
    }
    expect(plain(line.toJson()), isTrue);
    expect(plain(line.payload.toJson()), isTrue);
  });

  test('field defaults are filled in a view as in a plain map', () {
    final view = jsonObject({
      'visualState': {'showRange': true},
      'state': 'none',
    });
    expect(withFieldDefaults(view), {
      'visualState': {'showRange': true, 'showVisionCone': true},
      'state': 'none',
      'weapon': 'none',
    });
    expect(withFieldDefaults(view), withFieldDefaults(view.toJson()));
  });
}
