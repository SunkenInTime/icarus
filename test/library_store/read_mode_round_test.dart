import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_store/canvas_units.dart' show cloneStrategy;
import 'package:icarus/strategy/strategy_models.dart';

import '../library_rows/generated_strategies.dart';
import '../library_rows/library_sources.dart';

const fixtureVariable = 'ICARUS_READ_ROUND_FIXTURE';
const sourcesVariable = 'ICARUS_READ_ROUND_SOURCES';
const compareVariable = 'ICARUS_READ_ROUND_COMPARE';

StrategyData _generated(String id, String name) =>
    generatedStrategy(Optionals.set).copyWith(
      id: id,
      name: name,
      folderID: null,
      pages: [
        for (final (index, sortIndex) in [0, 1].indexed)
          generatedPage(
            id: '$id-p$index',
            sortIndex: sortIndex,
            optionals: Optionals.set,
            isAttack: index.isEven,
            itemPrefix: '$id-p$index',
          ).copyWith(imageData: const []),
      ],
    );

StrategyData _signedZero() {
  final strategy =
      cloneStrategy(_generated('round-signed-zero', 'Signed zero'));
  final agent = strategy.pages[0].agentData.first;
  agent.position = Offset(-0.0, agent.position.dy);
  return strategy;
}

StrategyData _interleaved() {
  final strategy = _generated('round-interleaved', 'Interleaved lineups');
  final graph = sharedSpotLineups('round-interleaved-l');
  return strategy.copyWith(pages: [
    strategy.pages[0].copyWith(
      lineUpGraph: LineUpGraph(
        origins: graph.origins,
        landings: graph.landings,
        links: [graph.links[0], graph.links[3], graph.links[1], graph.links[2]],
      ),
    ),
    strategy.pages[1],
  ]);
}

StrategyData _denseStrokes() {
  final strategy = _generated('round-dense', 'Dense strokes');
  final strokes = <DrawingElement>[
    for (var stroke = 0; stroke < 12; stroke++)
      FreeDrawing(
        id: 'round-dense-stroke-$stroke',
        listOfPoints: [
          for (var point = 0; point < 2500; point++)
            Offset(
              100 + point * 0.3,
              100 + stroke * 30 + (point % 40) * 0.5,
            ),
        ],
        colorValue: 0xFFE11D48,
        thickness: 4,
        isDotted: false,
        hasArrow: false,
      ),
  ];
  return strategy.copyWith(pages: [
    strategy.pages[0].copyWith(drawingData: strokes),
    strategy.pages[1],
  ]);
}

Future<void> _write(
  Directory out,
  Iterable<StrategyData> strategies,
  Iterable<Folder> folders,
) async {
  await out.create(recursive: true);
  Hive.init(out.path);
  final strategyBox =
      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  final folderBox = await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
  for (final strategy in strategies) {
    await strategyBox.put(strategy.id, strategy.copyWith());
  }
  for (final folder in folders) {
    await folderBox.put(folder.id, folderAsHiveHoldsIt(folder));
  }
  await Hive.close();
}

List<int> _bytes(StrategyData strategy) {
  final writer = BinaryWriterImpl(Hive)
    ..write(strategy.copyWith(lastEdited: DateTime.utc(2000)));
  return writer.toBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
  });

  final fixture = Platform.environment[fixtureVariable];
  final sources = Platform.environment[sourcesVariable];
  final compare = Platform.environment[compareVariable];

  test(
    'writes the read-mode round library: the source stores, each name made '
    'unique so the driver can find its tile, plus a strategy with an agent at '
    'x = -0.0, one with lineups saved interleaved, and one page of dense '
    'strokes',
    skip: fixture == null || sources == null
        ? 'set $fixtureVariable to a new folder and $sourcesVariable to Hive '
            'stores separated by ;'
        : false,
    () async {
      final strategies = <String, StrategyData>{};
      final folders = <String, Folder>{};
      for (final source in sources!.split(';')) {
        final loaded = await loadHiveStore(Directory(source));
        for (final strategy in loaded.strategies) {
          strategies[strategy.id] = strategy;
        }
        for (final folder in loaded.folders) {
          folders[folder.id] = folder;
        }
      }
      for (final made in [_signedZero(), _interleaved(), _denseStrokes()]) {
        strategies[made.id] = made;
      }
      final seen = <String, int>{};
      final named = [
        for (final strategy in strategies.values)
          switch (seen[strategy.name] = (seen[strategy.name] ?? 0) + 1) {
            1 => strategy,
            final copy => strategy.copyWith(name: '${strategy.name} ($copy)'),
          },
      ];
      await _write(Directory(fixture!), named, folders.values);
    },
  );

  test(
    'compares two libraries strategy by strategy in Hive encoding, save time '
    'aside, and names what differs',
    skip: compare == null
        ? 'set $compareVariable to <before store>:<after store>'
        : false,
    () async {
      final [before, after] = compare!.split(':');
      final left = {
        for (final strategy
            in (await loadHiveStore(Directory(before))).strategies)
          strategy.id: strategy,
      };
      final right = {
        for (final strategy
            in (await loadHiveStore(Directory(after))).strategies)
          strategy.id: strategy,
      };
      final lines = <String>[];
      for (final id in {...left.keys, ...right.keys}) {
        final a = left[id];
        final b = right[id];
        if (a == null || b == null) {
          lines.add('$id: only in ${a == null ? 'after' : 'before'}');
          continue;
        }
        if (const ListEquality<int>().equals(_bytes(a), _bytes(b))) continue;
        lines.add('$id "${a.name}": ${strategyDifferences(a, b).join(', ')}');
      }
      // ignore: avoid_print
      print('ROUND ${left.length} strategies before, ${right.length} after, '
          '${lines.length} differ');
      for (final line in lines) {
        // ignore: avoid_print
        print('ROUND $line');
      }
    },
  );
}
