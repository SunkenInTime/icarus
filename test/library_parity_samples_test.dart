import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/strategy_cloud_migration.dart';
import 'package:path/path.dart' as path;

const _samplesPath = 'tool/library_parity/samples.json';

Future<List<StrategyPage>> _fixturePages() async {
  final fixture = File(
    path.join(
      'test',
      'fixtures',
      'strategy_integrity',
      'canvas-compatibility-v97.ica',
    ),
  );
  final archive = ZipDecoder().decodeBytes(await fixture.readAsBytes());
  final entry = archive.files.singleWhere(
    (file) => path.extension(file.name).toLowerCase() == '.json',
  );
  final strategy = jsonDecode(utf8.decode(entry.content as List<int>))
      as Map<String, dynamic>;
  return [
    for (final page in strategy['pages'] as List<dynamic>)
      await StrategyPage.fromJson(
        json: Map<String, dynamic>.from(page as Map),
        strategyID: 'samples',
        strategyName: 'Samples',
        isZip: true,
      ),
  ];
}

String _shape(Map<String, dynamic> payload) {
  final data = payload['data'] as Map<String, dynamic>;
  final keys = data.keys.toList()..sort();
  return [
    payload['kind'],
    payload['payloadVersion'],
    data['type'],
    data['kind'],
    keys.join(','),
  ].join('|');
}

Object? _sorted(Object? value) => switch (value) {
      Map<dynamic, dynamic>() => {
          for (final key in value.keys.map((key) => '$key').toList()..sort())
            key: _sorted(value[key]),
        },
      List<dynamic>() => [for (final item in value) _sorted(item)],
      _ => value,
    };

Future<Map<String, Object?>> _samples() async {
  final elements = <String, Map<String, dynamic>>{};
  final groups = <String, Map<String, dynamic>>{};
  for (final (index, page) in (await _fixturePages()).indexed) {
    final ops = <StrategyOp>[];
    appendMovedPageOps(
      ops,
      page,
      cloudPageId: 'page-$index',
      ids: MovedItemIds(),
    );
    for (final op in ops) {
      switch (op) {
        case ElementAddOp(:final payload):
          final data = Map<String, dynamic>.from(payload['data'] as Map)
            ..['id'] = 'sample';
          if (data.containsKey('assetId')) data['assetId'] = 'picture';
          final sample = {...payload, 'data': data};
          elements.putIfAbsent(_shape(sample), () => sample);
        case LineupAddOp(:final payload):
          final data = Map<String, dynamic>.from(payload['data'] as Map)
            ..['id'] = 'sample';
          final links = [
            for (final link in data['links'] as List<dynamic>)
              {
                ...Map<String, dynamic>.from(link as Map),
                'images': [
                  for (final (index, image)
                      in (link['images'] as List<dynamic>? ?? const []).indexed)
                    {
                      ...Map<String, dynamic>.from(image as Map),
                      'id': 'picture-$index'
                    },
                ],
              },
          ];
          data['links'] = links;
          groups.putIfAbsent(
              '${links.length}', () => {...payload, 'data': data});
        default:
          break;
      }
    }
  }
  final pages = await _fixturePages();
  final ability = pages.expand((page) => page.abilityData).first
    ..wallPath = const [Offset(12, 0), Offset(24, 6)];
  for (final (kind, data) in [
    ('utility', mapDoors.first.row(id: 'sample').toJson()),
    (
      'utility',
      PlacedUtility(
        type: UtilityType.customRectangle,
        position: const Offset(400, 300),
        id: 'sample',
        customWidth: 120,
        customLength: 80,
        isZone: true,
      ).toJson(),
    ),
    ('ability', ability.toJson()),
  ]) {
    final payload = cloudElementPayload(
      kind: kind,
      data: {
        ...Map<String, dynamic>.from(data),
        'elementType': kind,
        'id': 'sample'
      },
    );
    elements.putIfAbsent(_shape(payload), () => payload);
  }
  final shapes = elements.keys.toList()..sort();
  final sizes = groups.keys.toList()..sort();
  return {
    'elements': [for (final shape in shapes) _sorted(elements[shape])],
    'lineupGroups': [for (final size in sizes) _sorted(groups[size])],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the parity samples are what the app writes for the fixture', () async {
    final encoded = const JsonEncoder.withIndent(' ').convert(await _samples());
    final file = File(_samplesPath);
    if (Platform.environment['UPDATE_PARITY_SAMPLES'] == '1') {
      file.writeAsStringSync('$encoded\n');
    }
    expect(file.readAsStringSync().replaceAll('\r\n', '\n'), '$encoded\n');
  });
}
