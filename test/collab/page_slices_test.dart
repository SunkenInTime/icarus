import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/page_slices.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

import 'strategy_copy_fixtures.dart';
import 'subscribe_together_from_each.dart';

void main() {
  test('slices hold about ten elements each, from 1 to 16 slices', () {
    expect(pageSliceStarts(0), ['']);
    expect(pageSliceStarts(15), ['']);
    expect(pageSliceStarts(16), ['', '8']);
    expect(pageSliceStarts(42), ['', '4', '8', 'c']);
    expect(pageSliceStarts(87), ['', '2', '4', '6', '8', 'a', 'c', 'e']);
    expect(pageSliceStarts(500), ['', ...'123456789abcdef'.split('')]);
  });

  group('a watched page', () {
    late _Server server;
    late ConvexStrategyRepository repository;
    late List<RemotePageSnapshot> pages;
    late List<Object> errors;
    StreamSubscription<RemotePageSnapshot>? watching;

    setUp(() {
      server = _Server();
      repository = ConvexStrategyRepository(IcarusConvexApi(server));
      pages = [];
      errors = [];
    });
    tearDown(() => watching?.cancel());

    Future<void> watch() async {
      watching = repository
          .watchPageSnapshot(strategyPublicId: 'strategy', pagePublicId: 'p')
          .listen(pages.add, onError: errors.add);
      await pumpEventQueue();
    }

    /// The page with [count] agents, ids spread over the hexadecimal range;
    /// [moved] has its revision raised.
    List<Map<String, Object?>> agents(int count, {String? moved}) => [
          for (var index = 0; index < count; index++)
            agentRow(
              _id(index),
              'p',
              revision: _id(index) == moved ? 2 : 1,
            ),
        ];

    Future<void> watchSlicedPage(int count) async {
      await watch();
      server.publish(agents(count));
      server.publish(agents(count, moved: _id(1)));
      await pumpEventQueue();
    }

    test('is watched whole while it does not change', () async {
      await watch();
      server.publish(agents(20));
      await pumpEventQueue();

      expect(server.watched, ['page:getSnapshot']);
      expect(pages, hasLength(1));
    });

    test('the same answer again is no change', () async {
      // The web client hands over its cached answer, then the server's.
      await watch();
      server.publish(agents(20));
      server.publish(agents(20));
      await pumpEventQueue();

      expect(server.watched, ['page:getSnapshot']);
    });

    test('a small page stays whole when it changes', () async {
      await watch();
      server.publish(agents(10));
      server.publish(agents(10, moved: _id(1)));
      await pumpEventQueue();

      expect(server.watched, ['page:getSnapshot']);
      expect(pages, hasLength(2));
    });

    test('once it changes, is watched in slices covering every id', () async {
      await watchSlicedPage(20);

      expect(server.watched, [
        'page:getSnapshot',
        'page:getFrame',
        'page:getElementSlice from ""',
        'page:getElementSlice from "8"',
      ]);
      expect(server.slices.map((args) => args.value['toPublicId']?.toDart()),
          ['8', null]);
      for (final args in server.watchedArgs) {
        expect(
          args.value['clientProtocolVersion']?.toDart(),
          currentCloudProtocolVersion,
        );
      }
      // The slices carry it from here on.
      expect(server.cancelled, ['page:getSnapshot']);
    });

    test('put together from its slices, it is the page one read sends',
        () async {
      await watchSlicedPage(20);

      expect(pages, hasLength(3));
      // Ties in sortIndex (every agent here) by id, as the offline copy
      // orders them.
      final whole = server.page.toDart();
      final inPlaceOrder = ConvexValue.fromDart({
        ...whole,
        'elements': [...whole['elements']! as List<Object?>]..sort((a, b) =>
            ((a! as Map)['publicId'] as String)
                .compareTo((b! as Map)['publicId'] as String)),
      });
      expect(
        pages.last.serverAnswer?.toDart(),
        PageGetSnapshotResult.decode(inPlaceOrder, 'whole')
            .encode('pageSnapshot')
            .toDart(),
      );
    });

    test('one slice changing shows the page again', () async {
      await watchSlicedPage(20);

      server.publish(agents(20, moved: _id(3)));
      await pumpEventQueue();

      expect(pages, hasLength(4));
      expect(
        pages.last.elements.singleWhere((e) => e.publicId == _id(3)).revision,
        2,
      );
    });

    test('a write touching two slices shows the page once', () async {
      await watchSlicedPage(20);
      final before = pages.length;

      // Ids 0 and 9 sit in different slices.
      server.publish([
        for (final row in agents(20))
          row['publicId'] == _id(0) || row['publicId'] == _id(9)
              ? agentRow(row['publicId']! as String, 'p', revision: 3)
              : row,
      ]);
      await pumpEventQueue();

      expect(pages.length - before, 1);
    });

    test('read once while sliced, it answers with the latest live page',
        () async {
      await watchSlicedPage(20);
      server.publish(agents(20, moved: _id(5)));
      await pumpEventQueue();
      server.reads.clear();

      final read = await repository.fetchPageSnapshot(
        strategyPublicId: 'strategy',
        pagePublicId: 'p',
      );

      expect(server.reads, isEmpty);
      // The very answer the watch handed on, so whoever noted when it came
      // still knows.
      expect(read, same(pages.last));
      expect(
        read.elements.singleWhere((e) => e.publicId == _id(5)).revision,
        2,
      );
    });

    test('read once while whole, or after watching stops, it is read whole',
        () async {
      await watch();
      await repository.fetchPageSnapshot(
        strategyPublicId: 'strategy',
        pagePublicId: 'p',
      );
      expect(server.reads, ['page:getSnapshot']);

      server.publish(agents(20));
      server.publish(agents(20, moved: _id(1)));
      await pumpEventQueue();
      await watching!.cancel();
      watching = null;
      server.reads.clear();
      await repository.fetchPageSnapshot(
        strategyPublicId: 'strategy',
        pagePublicId: 'p',
      );
      expect(server.reads, ['page:getSnapshot']);
    });

    test('stopping it stops every slice', () async {
      await watchSlicedPage(20);
      await watching!.cancel();
      watching = null;

      expect(
        server.cancelled,
        unorderedEquals([
          'page:getSnapshot',
          'page:getFrame',
          'page:getElementSlice from ""',
          'page:getElementSlice from "8"',
        ]),
      );
    });

    test('once the slices are asked for, the whole page no longer shows',
        () async {
      await watch();
      server.holdParts = true;
      server.publish(agents(20));
      server.publish(agents(20, moved: _id(1)));
      await pumpEventQueue();
      final shown = pages.length;

      // The whole page answers before the slices do: on desktop the two
      // arrive apart, and the slices' first answer may be the older one.
      server.publish(agents(20, moved: _id(2)));
      await pumpEventQueue();
      expect(pages.length, shown);

      server.releaseParts();
      await pumpEventQueue();
      expect(pages.length, shown + 1);
      expect(
        pages.last.elements.singleWhere((e) => e.publicId == _id(2)).revision,
        2,
      );
    });

    test('a slice that fails fails the page', () async {
      await watchSlicedPage(20);

      server.fail('page:getElementSlice from "8"', StateError('refused'));
      await pumpEventQueue();

      expect(errors.single, isA<StateError>());
    });

    test(
        'while a slice fails, no page is put together and reads go to the '
        'server', () async {
      await watchSlicedPage(20);
      server.fail(
          'page:getElementSlice from "8"',
          const ConvexTransportError(
            rawCode: 'TRANSIENT',
            message: 'refused',
          ));
      await pumpEventQueue();
      final shown = pages.length;

      // The other slice answering alone shows nothing.
      server.answerAgain('page:getElementSlice from ""');
      await pumpEventQueue();
      expect(pages.length, shown);
      server.reads.clear();
      await repository.fetchPageSnapshot(
        strategyPublicId: 'strategy',
        pagePublicId: 'p',
      );
      expect(server.reads, ['page:getSnapshot']);

      // Once every slice answers again, the page is live again.
      server.publish(agents(20, moved: _id(9)));
      await pumpEventQueue();
      expect(pages.length, shown + 1);
      server.reads.clear();
      final read = await repository.fetchPageSnapshot(
        strategyPublicId: 'strategy',
        pagePublicId: 'p',
      );
      expect(server.reads, isEmpty);
      expect(read, same(pages.last));
    });
  });
}

String _id(int index) =>
    '${'0123456789abcdef'[index % 16]}${index.toString().padLeft(2, '0')}';

/// One page, 'p', answered whole (page:getSnapshot) or in parts
/// (page:getFrame, page:getElementSlice) from the same rows, live or read
/// once.
final class _Server with SubscribeTogetherFromEach implements ConvexTransport {
  ConvexObject page = pageAnswer('p');
  final watched = <String>[];
  final watchedArgs = <ConvexObject>[];
  final slices = <ConvexObject>[];
  final reads = <String>[];
  final cancelled = <String>[];
  final _live =
      <String, (String, ConvexObject, StreamController<ConvexValue>)>{};

  /// While set, the parts (frame and slices) don't answer.
  bool holdParts = false;

  void publish(List<Map<String, Object?>> elements) {
    page = pageAnswer(
      'p',
      elements: elements,
      lineups: [lineupRow('lineup', 'p', 'shot')],
      assets: [assetRow('shot')],
    );
    for (final (name, args, controller) in _live.values) {
      if (holdParts && name != 'page:getSnapshot') continue;
      controller.add(_answer(name, args));
    }
  }

  /// Every part answers with what the server holds now.
  void releaseParts() {
    holdParts = false;
    for (final (name, args, controller) in _live.values) {
      if (name != 'page:getSnapshot') controller.add(_answer(name, args));
    }
  }

  void fail(String key, Object error) => _live[key]!.$3.addError(error);

  /// The live query [key] answers again with what the server holds now.
  void answerAgain(String key) {
    final (name, args, controller) = _live[key]!;
    controller.add(_answer(name, args));
  }

  ConvexValue _answer(String name, ConvexObject args) {
    final whole = page.toDart();
    switch (name) {
      case 'page:getSnapshot':
        return page;
      case 'page:getFrame':
        return ConvexValue.fromDart({
          'page': whole['page'],
          'content': whole['content'],
          'lineups': whole['lineups'],
          'assets': whole['assets'],
        });
      case 'page:getElementSlice':
        final from = args.value['fromPublicId']!.toDart() as String;
        final to = args.value['toPublicId']?.toDart() as String?;
        return ConvexValue.fromDart({
          'elements': [
            for (final element in whole['elements']! as List<Object?>)
              if (_inRange((element! as Map)['publicId'] as String, from, to))
                element,
          ],
          'assets': const <Object?>[],
        });
    }
    throw StateError('unexpected $name');
  }

  String _key(String name, ConvexObject args) => name == 'page:getElementSlice'
      ? '$name from "${args.value['fromPublicId']!.toDart()}"'
      : name;

  @override
  Future<ConvexValue> query(String name, ConvexObject args) async {
    reads.add(_key(name, args));
    return _answer(name, args);
  }

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    final key = _key(name, args);
    watched.add(key);
    watchedArgs.add(args);
    if (name == 'page:getElementSlice') slices.add(args);
    final controller = StreamController<ConvexValue>(
      onCancel: () => cancelled.add(key),
    );
    _live[key] = (name, args, controller);
    // A live part answers at once with what the server holds now; the whole
    // page answers when the test publishes.
    if (name != 'page:getSnapshot' && !holdParts) {
      controller.add(_answer(name, args));
    }
    return controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

bool _inRange(String id, String from, String? to) =>
    id.compareTo(from) >= 0 && (to == null || id.compareTo(to) < 0);
