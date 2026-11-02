import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/canvas_clipboard_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

/// The real provider, without the listeners that mark edits unsaved: debug
/// builds assert on the image provider reading a provider that listens to it.
class _Strategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: null,
        strategyName: null,
        source: StrategySource.local,
        storageDirectory: null,
      );
}

/// A page copied whole and pasted into a local strategy: the real clipboard,
/// strategy provider, page session and Hive box.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late Box<StrategyData> box;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('icarus-page-paste-');
    Hive.init(hiveDir.path);
    registerIcarusAdapters(Hive);
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => hiveDir.path);
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  StrategyPage page(
    String id,
    int sortIndex, {
    String? name,
    bool isAttack = true,
    List<PlacedAgentNode> agents = const [],
    List<PlacedAbility> abilities = const [],
    List<PlacedText> texts = const [],
    List<PlacedImage> images = const [],
    LineUpGraph? lineups,
    StrategySettings? settings,
  }) =>
      StrategyPage(
        id: id,
        name: name ?? 'Page ${sortIndex + 1}',
        isAutoNamed: name == null,
        drawingData: const [],
        agentData: agents,
        abilityData: abilities,
        textData: texts,
        imageData: images,
        utilityData: const [],
        sortIndex: sortIndex,
        isAttack: isAttack,
        settings: settings ?? StrategySettings(),
        lineUpOrigins: lineups?.origins ?? const [],
        lineUpLandings: lineups?.landings ?? const [],
        lineUpLinks: lineups?.links ?? const [],
      );

  Future<void> store(String id, MapValue map, List<StrategyPage> pages) =>
      box.put(
        id,
        StrategyData(
          id: id,
          name: id,
          mapData: map,
          versionNumber: Settings.versionNumber,
          lastEdited: DateTime.utc(2026),
          folderID: null,
          pages: pages,
        ),
      );

  Future<void> open(ProviderContainer app, String id, {String? pageId}) async {
    final strategy = box.get(id)!;
    final session = app.read(strategyPageSessionProvider.notifier);
    app.read(strategyProvider.notifier).setFromState(StrategyState(
          strategyId: id,
          strategyName: id,
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
          activePageId: pageId ?? strategy.pages.first.id,
        ));
    await session.initializeForStrategy(
      strategyId: id,
      source: StrategySource.local,
      selectFirstPageIfNeeded: true,
      preferredPageId: pageId ?? strategy.pages.first.id,
    );
  }

  ProviderContainer app() {
    final container = ProviderContainer(
      overrides: [strategyProvider.overrideWith(_Strategy.new)],
    );
    addTearDown(container.dispose);
    container.listen(strategyPageSessionProvider, (_, __) {});
    container.listen(canvasClipboardProvider, (_, __) {});
    return container;
  }

  void copyPage(ProviderContainer container, String name) =>
      container.read(canvasClipboardProvider.notifier).copyPage(
            name: name,
            isAutoNamed: false,
            readPictures: (ids) async => {
              for (final MapEntry(key: id, value: extension) in ids.entries)
                id: (
                  bytes: Uint8List.fromList([1, 2, 3]),
                  fileExtension: extension,
                ),
            },
          );

  final highTide = AgentData.agents[AgentType.harbor]!.abilities[1];
  final brimSmoke = AgentData.agents[AgentType.brimstone]!.abilities[2];

  test(
      'a page pastes whole into another strategy, after the page on screen, '
      'and opens', () async {
    final picture = PlacedImage(
      id: 'pic',
      position: const Offset(300, 300),
      aspectRatio: 1,
      scale: 100,
      fileExtension: '.png',
    );
    await store('from', MapValue.ascent, [
      page('a', 0),
      page(
        'b',
        1,
        name: 'B retake',
        isAttack: false,
        settings: StrategySettings(agentSize: 50),
        agents: [
          PlacedAgent(
            id: 'jett',
            type: AgentType.jett,
            position: const Offset(100, 100),
          )..caption = 'entry',
        ],
        abilities: [
          PlacedAbility(
            id: 'wall',
            data: highTide,
            position: const Offset(200, 200),
            wallPath: const [Offset(0, 0), Offset(40, 90)],
          ),
        ],
        images: [picture],
        lineups: LineUpGraph(
          origins: [
            LineUpOrigin(
              id: 'lo',
              agent: PlacedAgent(
                id: 'lo',
                type: AgentType.brimstone,
                position: const Offset(650, 700),
                lineUpID: 'lo',
              ),
            ),
          ],
          landings: [
            LineUpLanding(
              id: 'll',
              ability: PlacedAbility(
                id: 'll',
                data: brimSmoke,
                position: const Offset(760, 560),
                lineUpID: 'll',
              ),
            ),
          ],
          links: [
            LineUpLink(
              id: 'lk',
              originId: 'lo',
              landingId: 'll',
              images: [SimpleImageData(id: 'shot', fileExtension: '.png')],
            ),
          ],
        ),
      ),
    ]);
    await store('to', MapValue.ascent, [page('x', 0), page('y', 1)]);

    final container = app();
    await open(container, 'from', pageId: 'b');
    copyPage(container, 'B retake');
    await open(container, 'to', pageId: 'x');

    final refusal =
        await container.read(canvasClipboardProvider.notifier).paste();
    expect(refusal, isNull);

    final pages = [...box.get('to')!.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    expect(pages.map((item) => item.name), ['Page 1', 'B retake', 'Page 3']);
    final pasted = pages[1];
    expect(
      container.read(strategyPageSessionProvider).activePageId,
      pasted.id,
    );
    expect(container.read(mapProvider).isAttack, isFalse);
    expect(container.read(strategySettingsProvider).agentSize, 50);

    final agent = pasted.agentData.single;
    expect(agent.id, isNot('jett'));
    expect(pageCopyRoot(agent.id), 'jett');
    expect(agent.caption, 'entry');
    expect(pasted.abilityData.single.wallPath, const [
      Offset(0, 0),
      Offset(40, 90),
    ]);

    // Pictures are this strategy's own now.
    final image = pasted.imageData.single;
    expect(image.pictureId, isNot('pic'));
    final file = await PlacedImageProvider.getImageFile(
      strategyID: 'to',
      imageID: image.pictureId,
      fileExtension: '.png',
    );
    expect(await file.exists(), isTrue);
    final link = pasted.lineUpGraph.links.single;
    expect(link.id, isNot('lk'));
    expect(link.images.single.id, isNot('shot'));
    expect(pasted.lineUpGraph.origins.single.id, link.originId);
    expect(
      pasted.lineUpGraph.landings.single.ability.lineUpID,
      link.landingId,
    );

    // The source is as it was.
    expect(box.get('from')!.pages[1].agentData.single.id, 'jett');
  });

  test('a page from another map adds nothing', () async {
    await store('ascent', MapValue.ascent, [page('a', 0)]);
    await store('bind', MapValue.bind, [page('b', 0)]);
    final container = app();
    await open(container, 'ascent');
    copyPage(container, 'Default');
    await open(container, 'bind');

    final refusal =
        await container.read(canvasClipboardProvider.notifier).paste();

    expect(refusal, PasteRefusal.otherMap);
    expect(box.get('bind')!.pages, hasLength(1));
  });

  test('Paste page puts the page after the row it was asked on', () async {
    await store('s', MapValue.ascent, [page('a', 0), page('b', 1)]);
    final container = app();
    await open(container, 's');
    copyPage(container, 'Copy');

    await container
        .read(canvasClipboardProvider.notifier)
        .paste(afterPageId: 'b');

    final pages = [...box.get('s')!.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    expect(pages.map((item) => item.name), ['Page 1', 'Page 2', 'Copy']);
  });

  test('an auto-named page takes its number where it lands', () async {
    await store('s2', MapValue.ascent, [page('a', 0), page('b', 1)]);
    final container = app();
    await open(container, 's2', pageId: 'b');
    container.read(canvasClipboardProvider.notifier).copyPage(
          name: 'Page 2',
          isAutoNamed: true,
          readPictures: (_) async => const {},
        );

    await container.read(canvasClipboardProvider.notifier).paste();

    final pages = box.get('s2')!.pages;
    expect(pages.map((item) => item.name), ['Page 1', 'Page 2', 'Page 3']);
    expect(pages.last.isAutoNamed, isTrue);
  });

  test('copying a page leaves the canvas agents untouched by the paste',
      () async {
    final jett = PlacedAgent(
      id: 'jett',
      type: AgentType.jett,
      position: const Offset(100, 100),
    );
    await store('own', MapValue.ascent, [
      page('a', 0, agents: [jett]),
    ]);
    final container = app();
    await open(container, 'own');
    copyPage(container, 'Copy');

    await container.read(canvasClipboardProvider.notifier).paste();
    await container.read(canvasClipboardProvider.notifier).paste();

    final pages = box.get('own')!.pages;
    expect(pages, hasLength(3));
    final ids = {for (final item in pages) item.agentData.single.id};
    expect(ids, hasLength(3), reason: 'every paste makes copies of its own');
    expect(container.read(agentProvider), hasLength(1));
    expect(container.read(abilityProvider), isEmpty);
    expect(container.read(placedImageProvider).images, isEmpty);
  });
}
