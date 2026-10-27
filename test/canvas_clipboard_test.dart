import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/canvas_clipboard_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

/// Where the open strategy keeps its files, for a test that puts a picture
/// there.
String? _storage;

class _OpenStrategy extends StrategyProvider {
  @override
  StrategyState build() {
    return StrategyState(
      strategyId: 'source-strategy',
      strategyName: null,
      source: StrategySource.local,
      storageDirectory: _storage,
      isOpen: true,
    );
  }

  void openOther() => state = const StrategyState(
        strategyId: 'other-strategy',
        strategyName: null,
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  void setUnsaved() {}
}

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [strategyProvider.overrideWith(_OpenStrategy.new)],
  );
  addTearDown(container.dispose);
  container.listen(canvasSelectionProvider, (_, __) {});
  container.listen(canvasClipboardProvider, (_, __) {});
  return container;
}

Line _line(String id) => Line(
      lineStart: const Offset(100, 100),
      lineEnd: const Offset(200, 200),
      color: Colors.white,
      isDotted: false,
      hasArrow: false,
      id: id,
    );

Future<Map<String, CopiedPicture?>> _noPictures(Map<String, String> ids) =>
    Future.value({for (final id in ids.keys) id: null});

/// Every picture as a few bytes, as a copy carries them.
Future<Map<String, CopiedPicture?>> _somePictures(Map<String, String> ids) =>
    Future.value({
      for (final MapEntry(key: id, value: extension) in ids.entries)
        id: (bytes: Uint8List.fromList([1, 2, 3]), fileExtension: extension),
    });

PlacedImage _image() => PlacedImage(
      id: 'img',
      position: const Offset(300, 300),
      aspectRatio: 1,
      scale: 100,
      fileExtension: '.png',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  late Directory storage;
  setUp(() {
    // The strategy's pictures 'img' and 'shot' are on disk, so a paste can
    // show them.
    storage = Directory.systemTemp.createTempSync('icarus-clipboard-');
    File('${storage.path}/images/img.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    File('${storage.path}/images/shot.png').writeAsBytesSync([1, 2, 3]);
    _storage = storage.path;
  });
  tearDown(() {
    _storage = null;
    storage.deleteSync(recursive: true);
  });

  test('a paste puts new copies where the originals are, in one step',
      () async {
    final container = _container();
    container.read(agentProvider.notifier).fromHive([
      PlacedAgent(
          id: 'a', type: AgentType.jett, position: const Offset(40, 50)),
    ]);
    container.read(drawingProvider.notifier).fromHive([
      _line('d'),
      FreeDrawing(
        id: 'free',
        listOfPoints: [const Offset(600, 600), const Offset(700, 620)],
        color: Colors.white,
        boundingBox: BoundingBox(
          min: const Offset(600, 600),
          max: const Offset(700, 620),
        ),
        isDotted: false,
        hasArrow: false,
      ),
    ]);
    container.read(placedImageProvider.notifier).fromHive([
      PlacedImage(
        id: 'img',
        position: const Offset(300, 300),
        aspectRatio: 1,
        scale: 100,
        fileExtension: '.png',
      ),
    ]);
    container.read(canvasSelectionProvider.notifier).selectAll();

    final copied = container
        .read(canvasClipboardProvider.notifier)
        .copySelection(_noPictures);
    final refusal =
        await container.read(canvasClipboardProvider.notifier).paste();

    expect(copied, 4);
    expect(refusal, isNull);
    final agents = container.read(agentProvider);
    expect(agents, hasLength(2));
    final pasted = agents.last;
    expect(pasted.id, isNot('a'));
    // Its root is the original, so a page transition still pairs them.
    expect(pageCopyRoot(pasted.id), 'a');
    expect(pasted.position, const Offset(40, 50));
    final drawings = container.read(drawingProvider).elements;
    expect(drawings, hasLength(4));
    expect((drawings[2] as Line).lineStart, const Offset(100, 100));
    expect(drawings.last.boundingBox?.max, const Offset(700, 620));
    // Pasted into the strategy it came from, it shows the same picture.
    final images = container.read(placedImageProvider).images;
    expect(images.last.pictureId, 'img');
    expect(container.read(canvasSelectionProvider), {
      (kind: SelectableKind.agent, id: pasted.id),
      (kind: SelectableKind.drawing, id: drawings[2].id),
      (kind: SelectableKind.drawing, id: drawings.last.id),
      (kind: SelectableKind.image, id: images.last.id),
    });

    container.read(actionProvider.notifier).undoAction();

    expect(container.read(agentProvider).map((agent) => agent.id), ['a']);
    expect(container.read(drawingProvider).elements, hasLength(2));
    expect(container.read(placedImageProvider).images, hasLength(1));
  });

  test('a paste on another map puts nothing down', () async {
    final container = _container();
    container.read(agentProvider.notifier).fromHive([
      PlacedAgent(
          id: 'a', type: AgentType.jett, position: const Offset(40, 50)),
    ]);
    container.read(canvasSelectionProvider.notifier).selectAll();
    container.read(canvasClipboardProvider.notifier).copySelection(_noPictures);

    container.read(mapProvider.notifier).updateMap(MapValue.bind);
    final refusal =
        await container.read(canvasClipboardProvider.notifier).paste();

    expect(refusal, PasteRefusal.otherMap);
    expect(container.read(agentProvider), hasLength(1));
  });

  test('a picture that could not be read keeps a paste out of another strategy',
      () async {
    final container = _container();
    container.read(placedImageProvider.notifier).fromHive([
      PlacedImage(
        id: 'img',
        position: const Offset(300, 300),
        aspectRatio: 1,
        scale: 100,
        fileExtension: '.png',
      ),
    ]);
    container.read(canvasSelectionProvider.notifier).selectAll();
    container.read(canvasClipboardProvider.notifier).copySelection(_noPictures);

    (container.read(strategyProvider.notifier) as _OpenStrategy).openOther();
    container.read(placedImageProvider.notifier).fromHive([]);
    final refusal =
        await container.read(canvasClipboardProvider.notifier).paste();

    expect(refusal, PasteRefusal.picturesMissing);
    expect(container.read(placedImageProvider).images, isEmpty);
  });

  test('a lineup, a text and an ability paste too', () async {
    final container = _container();
    final info = AgentData.agents[AgentType.brimstone]!.abilities[2];
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 't', position: const Offset(40, 40))..text = 'B main',
    ]);
    container.read(abilityProvider.notifier).fromHive([
      PlacedAbility(id: 's', data: info, position: const Offset(70, 70)),
    ]);
    container.read(lineUpProvider.notifier).addCopies(LineUpGraph(
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
                data: info,
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
        ));
    container.read(canvasSelectionProvider.notifier).selectAll();
    container.read(canvasClipboardProvider.notifier).copySelection(_noPictures);

    final refusal =
        await container.read(canvasClipboardProvider.notifier).paste();

    expect(refusal, isNull);
    expect(container.read(textProvider).last.text, 'B main');
    expect(container.read(abilityProvider), hasLength(2));
    final links = container.read(lineUpProvider).links;
    expect(links, hasLength(2));
    expect(links.last.images.single.id, 'shot');
  });

  test("a picture gone from its strategy comes back from the copy's bytes",
      () async {
    final container = _container();
    container.read(placedImageProvider.notifier).fromHive([_image()]);
    container.read(canvasSelectionProvider.notifier).selectAll();
    container
        .read(canvasClipboardProvider.notifier)
        .copySelection(_somePictures);
    // Its last use was cut and its file cleaned up.
    File('${storage.path}/images/img.png').deleteSync();

    final refusal =
        await container.read(canvasClipboardProvider.notifier).paste();

    expect(refusal, isNull);
    final pasted = container.read(placedImageProvider).images.last;
    expect(pasted.pictureId, isNot('img'));
    expect(pasted.id, pasted.pictureId);
  });

  test('an item with a very long imported id pastes under a plain id',
      () async {
    final container = _container();
    final long = 'imported-${'x' * 200}';
    container.read(agentProvider.notifier).fromHive([
      PlacedAgent(id: long, type: AgentType.jett, position: Offset.zero),
    ]);
    container.read(canvasSelectionProvider.notifier).selectAll();
    container.read(canvasClipboardProvider.notifier).copySelection(_noPictures);

    await container.read(canvasClipboardProvider.notifier).paste();

    final pasted = container.read(agentProvider).last.id;
    expect(pasted, isNot(contains('~cp1~')));
    expect(pasted.length, lessThan(50));
  });
}
