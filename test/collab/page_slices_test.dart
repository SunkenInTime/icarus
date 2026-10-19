import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/page_slices.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

import 'strategy_copy_fixtures.dart';

void main() {
  group('pageSliceStarts', () {
    test('about ten elements a slice, from 1 to 16 slices', () {
      expect(pageSliceStarts(0), ['']);
      expect(pageSliceStarts(15), ['']);
      expect(pageSliceStarts(16), ['', '8']);
      expect(pageSliceStarts(42), ['', '4', '8', 'c']);
      expect(pageSliceStarts(87), ['', '2', '4', '6', '8', 'a', 'c', 'e']);
      expect(pageSliceStarts(500), ['', ...'123456789abcdef'.split('')]);
    });
  });

  group('a page watched in slices', () {
    late _SliceServer server;
    late ConvexStrategyRepository repository;

    setUp(() {
      server = _SliceServer();
      repository = ConvexStrategyRepository(IcarusConvexApi(server));
    });

    Stream<RemotePageSnapshot> watch(int elementCount) =>
        repository.watchPageSnapshot(
          strategyPublicId: 'strategy',
          pagePublicId: 'page-a',
          elementCount: elementCount,
        );

    test('asks for the frame and slices covering every id', () async {
      final subscription = watch(42).listen((_) {});
      await pumpEventQueue();

      expect(server.asked.keys, ['frame', '', '4', '8', 'c']);
      for (final args in server.asked.values) {
        expect(
          args.value['clientProtocolVersion']?.toDart(),
          currentCloudProtocolVersion,
        );
        expect(args.value['acceptsPictureIds']?.toDart(), isTrue);
      }
      expect(
        [
          for (final start in ['', '4', '8', 'c'])
            server.asked[start]!.value['toPublicId']?.toDart(),
        ],
        ['4', '8', 'c', null],
      );
      await subscription.cancel();
    });

    test('shows the page only once every part answered, as one read would',
        () async {
      final pages = <RemotePageSnapshot>[];
      final subscription = watch(16).listen(pages.add);
      await pumpEventQueue();

      server.answer('frame', frameAnswer());
      server.answer('', sliceAnswer([agentRow('3-agent', 'page-a')]));
      await pumpEventQueue();
      expect(pages, isEmpty);

      server.answer(
        '8',
        sliceAnswer(
          [
            imageRow('b-copy', 'page-a', 'picture'),
            agentRow('9-agent', 'page-a'),
          ],
          assets: [assetRow('picture')],
          aliases: [assetRow('picture'), 'b-copy'],
        ),
      );
      await pumpEventQueue();

      final whole = pageAnswer(
        'page-a',
        elements: [
          agentRow('3-agent', 'page-a'),
          agentRow('9-agent', 'page-a'),
          imageRow('b-copy', 'page-a', 'picture'),
        ],
        lineups: [lineupRow('lineup', 'page-a', 'shot')],
        assets: [
          aliasOf(assetRow('picture'), 'b-copy'),
          assetRow('picture'),
          assetRow('shot'),
        ],
      );
      expect(pages, hasLength(1));
      expect(
        pages.single.serverAnswer?.toDart(),
        PageGetSnapshotResult.decode(whole, 'whole')
            .encode('pageSnapshot')
            .toDart(),
      );
      await subscription.cancel();
    });

    test('a real asset wins over an alias under the same id', () async {
      final pages = <RemotePageSnapshot>[];
      final subscription = watch(0).listen(pages.add);
      await pumpEventQueue();

      // The lineup in the frame shows an image whose id an alias takes too.
      server.answer('frame', frameAnswer(lineupImage: 'b-copy'));
      server.answer(
        '',
        sliceAnswer(
          [imageRow('b-copy', 'page-a', 'picture')],
          assets: [assetRow('picture')],
          aliases: [assetRow('picture'), 'b-copy'],
        ),
      );
      await pumpEventQueue();

      expect(
        pages.single.assetsById['b-copy']?.url,
        'https://images.example/b-copy.png',
      );
      await subscription.cancel();
    });

    test('shows the page again when one slice changes', () async {
      final pages = <RemotePageSnapshot>[];
      final subscription = watch(16).listen(pages.add);
      await pumpEventQueue();
      server.answer('frame', frameAnswer());
      server.answer('', sliceAnswer([agentRow('3-agent', 'page-a')]));
      server.answer('8', sliceAnswer([agentRow('9-agent', 'page-a')]));
      await pumpEventQueue();

      server.answer(
        '8',
        sliceAnswer([agentRow('9-agent', 'page-a', revision: 2, x: 40)]),
      );
      await pumpEventQueue();

      expect(pages, hasLength(2));
      expect(
        pages.last.elements.map((e) => (e.publicId, e.revision)),
        [('3-agent', 1), ('9-agent', 2)],
      );
      await subscription.cancel();
    });

    test('parts answering together show the page once', () async {
      final pages = <RemotePageSnapshot>[];
      final subscription = watch(16).listen(pages.add);
      await pumpEventQueue();
      server.answer('frame', frameAnswer());
      server.answer('', sliceAnswer([agentRow('3-agent', 'page-a')]));
      server.answer('8', sliceAnswer([agentRow('9-agent', 'page-a')]));
      await pumpEventQueue();

      // One write moved an agent in each slice.
      server.answer(
        '',
        sliceAnswer([agentRow('3-agent', 'page-a', revision: 2)]),
      );
      server.answer(
        '8',
        sliceAnswer([agentRow('9-agent', 'page-a', revision: 2)]),
      );
      await pumpEventQueue();

      expect(pages, hasLength(2));
      expect(pages.last.elements.map((e) => e.revision), [2, 2]);
      await subscription.cancel();
    });

    test('a part that fails fails the page', () async {
      final errors = <Object>[];
      final subscription = watch(16).listen((_) {}, onError: errors.add);
      await pumpEventQueue();

      server.fail('8', StateError('slice refused'));
      await pumpEventQueue();

      expect(errors.single, isA<StateError>());
      await subscription.cancel();
    });

    test('stopping the page stops every part', () async {
      final subscription = watch(42).listen((_) {});
      await pumpEventQueue();
      await subscription.cancel();

      expect(server.cancelled, unorderedEquals(['frame', '', '4', '8', 'c']));
    });
  });
}

ConvexObject frameAnswer({String lineupImage = 'shot'}) =>
    ConvexValue.fromDart({
      'page': pageRow('page-a'),
      'content': contentRow(),
      'lineups': [lineupRow('lineup', 'page-a', lineupImage)],
      'assets': [assetRow(lineupImage)],
    }) as ConvexObject;

/// [aliases] alternates a picture's asset row and the image id it is shown
/// under.
ConvexObject sliceAnswer(
  List<Map<String, Object?>> elements, {
  List<Map<String, Object?>> assets = const [],
  List<Object> aliases = const [],
}) =>
    ConvexValue.fromDart({
      'elements': elements,
      'assets': assets,
      'aliases': [
        for (var index = 0; index < aliases.length; index += 2)
          aliasOf(
            aliases[index] as Map<String, Object?>,
            aliases[index + 1] as String,
          ),
      ],
    }) as ConvexObject;

Map<String, Object?> aliasOf(Map<String, Object?> asset, String id) =>
    {...asset, 'publicId': id};

/// Answers page:getFrame (keyed 'frame') and page:getElementSlice (keyed by
/// its start) as a test says.
final class _SliceServer implements ConvexTransport {
  final asked = <String, ConvexObject>{};
  final cancelled = <String>[];
  final _streams = <String, StreamController<ConvexValue>>{};

  void answer(String key, ConvexValue value) => _streams[key]!.add(value);

  void fail(String key, Object error) => _streams[key]!.addError(error);

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    final key = switch (name) {
      'page:getFrame' => 'frame',
      'page:getElementSlice' => args.value['fromPublicId']!.toDart() as String,
      _ => throw StateError('unexpected $name'),
    };
    asked[key] = args;
    final controller = StreamController<ConvexValue>(
      onCancel: () => cancelled.add(key),
    );
    _streams[key] = controller;
    return controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
