import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

import '../library_rows/generated_strategies.dart';
import 'unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

Uint8List _bytes(Object? value) =>
    (BinaryWriterImpl(Hive)..write(value)).toBytes();

List<PlacedWidget> _items(StrategyPage page) =>
    [...page.agentData, ...page.abilityData, ...page.utilityData];

StrategyPage _first(String id) {
  final generated = generatedPage(
    id: '$id-p0',
    sortIndex: 0,
    optionals: Optionals.set,
    isAttack: true,
  );
  return StrategyPage(
    id: generated.id,
    name: generated.name,
    drawingData: generated.drawingData,
    agentData: [
      ...generated.agentData,
      PlacedAgent(
        id: '$id-empty-caption',
        type: AgentType.sova,
        position: const Offset(333.333, 12.0625),
        weapon: WeaponType.sheriff,
      )..caption = '',
    ],
    abilityData: [
      ...generated.abilityData,
      PlacedAbility(
        id: '$id-empty-wall',
        data: AgentData.agents[AgentType.harbor]!.abilities[1],
        position: const Offset(250.75, 99.875),
        wallPath: const [],
      ),
    ],
    textData: generated.textData,
    imageData: generated.imageData,
    utilityData: generated.utilityData,
    sortIndex: generated.sortIndex,
    isAttack: generated.isAttack,
    settings: generated.settings,
    lineUpOrigins: generated.lineUpOrigins,
    lineUpLandings: generated.lineUpLandings,
    lineUpLinks: generated.lineUpLinks,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  setUpAll(() {
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    appProviderContainer = container;
  });
  setUp(() async => openUnitHive());
  tearDown(() async => Hive.close());

  test(
      'a load puts on the canvas, and a save after one unrelated edit writes '
      'back, the very bytes Hive stored for every other agent, ability and '
      'utility', () async {
    const id = 'stored-items';
    final second = generatedPage(
      id: '$id-p1',
      sortIndex: 1,
      optionals: Optionals.unset,
      isAttack: false,
      itemPrefix: '$id-p1',
    );
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
      id,
      generatedStrategy(Optionals.set)
          .copyWith(id: id, pages: [_first(id), second]),
    );
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).close();
    var box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    final stored = box.get(id)!;
    final record = _bytes(stored);
    final storedItems = {
      for (final page in stored.pages)
        for (final item in _items(page)) item.id: _bytes(item),
    };
    final storedSecondPage = _bytes(stored.pages[1]);
    final shownIds = [for (final item in _items(stored.pages[0])) item.id];
    expect(
        stored.pages[0].agentData.whereType<PlacedViewConeAgent>(), isNotEmpty);
    expect(
        stored.pages[0].agentData.whereType<PlacedCircleAgent>(), isNotEmpty);
    expect(stored.pages[0].utilityData.map((u) => u.isZone).toSet(),
        {true, false});

    final h = await openInEditor(container, stored);
    addTearDown(h.dispose);

    expect(_bytes(box.get(id)), record, reason: 'the record after the load');
    final onCanvas = <PlacedWidget>[
      ...container.read(agentProvider),
      ...container.read(abilityProvider),
      ...container.read(utilityProvider),
    ];
    expect([for (final item in onCanvas) item.id], shownIds);
    for (final item in onCanvas) {
      expect(_bytes(item), storedItems[item.id], reason: '${item.id} loaded');
    }

    const moved = '$id-p0-utility-spike';
    final spike = container
        .read(utilityProvider)
        .firstWhere((utility) => utility.id == moved);
    container
        .read(utilityProvider.notifier)
        .updatePosition(spike.position + const Offset(21.5, 13.25), moved);
    await container.read(strategyProvider.notifier).forceSaveNow(id);
    await h.settle();
    await box.close();
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    final saved = box.get(id)!;

    for (final item in _items(saved.pages[0])) {
      if (item.id == moved) {
        expect(_bytes(item), isNot(storedItems[item.id]), reason: moved);
      } else {
        expect(_bytes(item), storedItems[item.id], reason: '${item.id} saved');
      }
    }
    expect(
      [
        for (final item in _items(saved.pages[0]))
          if (item.id != moved) item.id,
      ],
      [
        for (final itemId in shownIds)
          if (itemId != moved) itemId,
      ],
    );
    expect(_bytes(saved.pages[1]), storedSecondPage, reason: 'second page');
  });
}
