import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/page_slices.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

import 'stamped_over.dart';
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

  group('a page watched stamped', () {
    late _Server server;
    late StampedOver stamped;
    late ConvexStrategyRepository repository;
    late List<Stamped<RemotePageSnapshot>> answers;
    late List<Object> errors;
    StreamSubscription<Stamped<RemotePageSnapshot>>? watching;

    setUp(() {
      server = _Server();
      stamped = StampedOver(server);
      repository = ConvexStrategyRepository.stamped(stamped);
      answers = [];
      errors = [];
    });
    tearDown(() => watching?.cancel());

    ResultStamp at(int snapshot) => ResultStamp(
          client: 1,
          connection: 1,
          snapshot: snapshot,
          serverTime: 1000 + snapshot,
        );

    RemotePageSnapshot pageOf(Stamped<RemotePageSnapshot> answer) =>
        (answer as StampedValue<RemotePageSnapshot>).value;

    int revisionOf(Stamped<RemotePageSnapshot> answer, String id) =>
        pageOf(answer).elements.singleWhere((e) => e.publicId == id).revision;

    Future<void> watch() async {
      watching = repository
          .watchPageSnapshotStamped(
            strategyPublicId: 'strategy',
            pagePublicId: 'p',
          )
          .listen(answers.add, onError: errors.add);
      await pumpEventQueue();
    }

    List<Map<String, Object?>> agents(int count, {String? moved}) => [
          for (var index = 0; index < count; index++)
            agentRow(
              _id(index),
              'p',
              revision: _id(index) == moved ? 2 : 1,
            ),
        ];

    Future<void> watchSlicedPage() async {
      await watch();
      server.publish(agents(20));
      server.publish(agents(20, moved: _id(1)));
      await pumpEventQueue();
    }

    test(
        'hands over from the whole page to its slices as the plain watch '
        'does, each page with the stamp it came with, and a read of it is '
        'answered from the slices', () async {
      await watchSlicedPage();

      expect(stamped.calls, [
        'subscribeStamped page:getSnapshot',
        'subscribeTogetherStamped page:getFrame,page:getElementSlice,'
            'page:getElementSlice',
      ]);
      expect(server.cancelled, ['page:getSnapshot']);
      expect([
        for (final answer in answers) answer.stamp
      ], [
        at(1),
        at(2),
        at(3),
      ]);
      expect(revisionOf(answers[1], _id(1)), 2);
      expect(revisionOf(answers[2], _id(1)), 2);

      final read = await repository.fetchPageSnapshot(
        strategyPublicId: 'strategy',
        pagePublicId: 'p',
      );
      expect(server.reads, isEmpty);
      expect(read.elements, pageOf(answers[2]).elements);
      expect(errors, isEmpty);
    });

    test(
        'slices that fail before they answer give the whole page again at '
        'the stamp it came with, and it stays live', () async {
      await watch();
      server.refuseParts = true;
      server.publish(agents(20));
      server.publish(agents(20, moved: _id(1)));
      await pumpEventQueue();

      expect(answers.length, greaterThan(2));
      for (final replay in answers.skip(2)) {
        expect(replay.stamp, at(2));
        expect(revisionOf(replay, _id(1)), 2);
      }

      server.publish(agents(20, moved: _id(2)));
      await pumpEventQueue();
      expect(answers.last.stamp, at(3));
      expect(revisionOf(answers.last, _id(2)), 2);
      expect(errors, isEmpty);
    });

    test(
        'a refusal of the whole page comes as a StampedError at its stamp, '
        'and the watch goes on', () async {
      await watch();
      server.publish(agents(4));
      await pumpEventQueue();
      server.fail(
        'page:getSnapshot',
        const ConvexTransportError(rawCode: 'FORBIDDEN', message: 'page'),
      );
      await pumpEventQueue();
      server.publish(agents(5));
      await pumpEventQueue();

      expect(errors, isEmpty);
      expect([
        for (final answer in answers) answer.stamp
      ], [
        at(1),
        at(2),
        at(3),
      ]);
      expect(
        (answers[1] as StampedError<RemotePageSnapshot>).error.rawCode,
        'FORBIDDEN',
      );
      expect(pageOf(answers[2]).elements, hasLength(5));
    });

    test(
        'a refusal of a slice comes as a StampedError at its stamp, and a '
        'read then goes to the server', () async {
      await watchSlicedPage();
      server.fail(
        'page:getElementSlice from "8"',
        const ConvexTransportError(rawCode: 'FORBIDDEN', message: 'slice'),
      );
      await pumpEventQueue();

      expect(errors, isEmpty);
      expect(answers.last.stamp, at(4));
      expect(
        (answers.last as StampedError<RemotePageSnapshot>).error.rawCode,
        'FORBIDDEN',
      );

      await repository.fetchPageSnapshot(
        strategyPublicId: 'strategy',
        pagePublicId: 'p',
      );
      expect(server.reads, ['page:getSnapshot']);
    });
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

    test('slices that fail before they answer leave the whole page live',
        () async {
      await watch();
      server.refuseParts = true;
      server.publish(agents(20));
      server.publish(agents(20, moved: _id(1)));
      await pumpEventQueue();
      expect(errors, isEmpty);

      // A teammate's edit still shows, through the whole page.
      server.publish(agents(20, moved: _id(2)));
      await pumpEventQueue();
      expect(
        pages.last.elements.singleWhere((e) => e.publicId == _id(2)).revision,
        2,
      );

      // Once the slices can be watched, the next change moves to them.
      server.refuseParts = false;
      server.publish(agents(20, moved: _id(3)));
      await pumpEventQueue();
      expect(server.watched, contains('page:getFrame'));
      expect(server.cancelled, contains('page:getSnapshot'));
      expect(
        pages.last.elements.singleWhere((e) => e.publicId == _id(3)).revision,
        2,
      );
      expect(errors, isEmpty);
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

  tapTests();
}

void tapTests() {
  group('the result tap', () {
    late _Server server;
    late ConvexStrategyRepository repository;
    late _Tap tap;
    late List<Object> order;
    StreamSubscription<RemotePageSnapshot>? watching;

    setUp(() {
      server = _Server();
      repository = ConvexStrategyRepository(IcarusConvexApi(server));
      order = [];
      tap = _Tap(order);
      repository.tap = tap;
    });
    tearDown(() => watching?.cancel());

    Future<void> watch() async {
      watching = repository
          .watchPageSnapshot(strategyPublicId: 'strategy', pagePublicId: 'p')
          .listen(
            (page) => order.add(('editor', page)),
            onError: (Object error) => order.add(('editor error', error)),
          );
      await pumpEventQueue();
    }

    List<Map<String, Object?>> agents(int count, {String? moved}) => [
          for (var index = 0; index < count; index++)
            agentRow(
              _id(index),
              'p',
              revision: _id(index) == moved ? 2 : 1,
            ),
        ];

    List<RemotePageSnapshot> editorPages() => [
          for (final event in order)
            if (event case ('editor', final RemotePageSnapshot page)) page,
        ];

    test(
        'hears of each whole answer after the editor has it, with the '
        'payload the server sent and what it heard at delivery', () async {
      tap.stamp = 'at delivery';
      watching = repository
          .watchPageSnapshot(strategyPublicId: 'strategy', pagePublicId: 'p')
          .listen((page) {
        order.add(('editor', page));
        tap.stamp = 'after delivery';
      });
      await pumpEventQueue();
      server.publish(agents(3));
      await pumpEventQueue();

      expect(order.map((event) => (event as (String, Object)).$1),
          ['editor', 'tap']);
      final (strategyId, page, heard, throughShareLink) = tap.pages.single;
      expect(strategyId, 'strategy');
      expect(heard, 'at delivery');
      expect(throughShareLink, isFalse);
      expect(page, same(editorPages().single));
      final sent = (server.page.toDart()['elements']! as List<Object?>)
          .cast<Map<Object?, Object?>>();
      expect(
        [for (final element in page.elements) element.payload],
        [
          for (final element in sent)
            (element['payload']! as Map<Object?, Object?>)
                .cast<String, Object?>(),
        ],
      );
    });

    test(
        'hears of every page the editor is given, the saved whole page the '
        'slices fall back to included', () async {
      await watch();
      server.holdParts = true;
      server.publish(agents(20));
      server.publish(agents(20, moved: _id(1)));
      await pumpEventQueue();
      server.publish(agents(20, moved: _id(2)));
      await pumpEventQueue();
      server.fail('page:getFrame', StateError('the slices failed'));
      await pumpEventQueue();

      final shown = editorPages();
      expect(
        shown.last.elements.singleWhere((e) => e.publicId == _id(2)).revision,
        2,
      );
      expect(tap.pages.map((page) => page.$2), shown);
    });

    test('a read answered from the live slices is not heard of again',
        () async {
      await watch();
      server.publish(agents(20));
      server.publish(agents(20, moved: _id(1)));
      await pumpEventQueue();
      final heard = tap.pages.length;

      await repository.fetchPageSnapshot(
        strategyPublicId: 'strategy',
        pagePublicId: 'p',
      );
      await pumpEventQueue();
      expect(tap.pages, hasLength(heard));
    });

    test(
        'hears of a read from the server once, after its caller has it, '
        'marked when it went through a share link; a failed read reaches '
        'its caller unchanged and is not heard of', () async {
      final read = await repository.fetchPageSnapshot(
        strategyPublicId: 'strategy',
        pagePublicId: 'p',
        shareToken: 'link',
      );
      order.add(('caller', read));
      await pumpEventQueue();
      expect(order.map((event) => (event as (String, Object)).$1),
          ['caller', 'tap']);
      expect(tap.pages.single.$4, isTrue);

      final broke = StateError('the read broke');
      server.failReads = broke;
      await expectLater(
        repository.fetchPageSnapshot(
          strategyPublicId: 'strategy',
          pagePublicId: 'p',
        ),
        throwsA(same(broke)),
      );
      await pumpEventQueue();
      expect(tap.pages, hasLength(1));
    });

    group('a tap that throws changes nothing for the editor', () {
      for (final method in ['heard', 'pageArrived']) {
        test('in $method', () async {
          tap.throwOn = method;
          await watch();
          server.publish(agents(3));
          server.publish(agents(3, moved: _id(1)));
          await pumpEventQueue();
          final read = await repository.fetchPageSnapshot(
            strategyPublicId: 'strategy',
            pagePublicId: 'p',
          );

          expect(editorPages(), hasLength(2));
          expect(read.elements, hasLength(3));
          expect(tap.pages, isEmpty);
          expect(tap.tapFailures, hasLength(method == 'heard' ? 3 : 2));
        });
      }
    });
  });
}

final class _Tap implements ResultTap {
  _Tap(this.order);

  final List<Object> order;
  final pages = <(String, RemotePageSnapshot, Object?, bool)>[];
  final tapFailures = <Object>[];
  Object? stamp;
  String? throwOn;

  void _maybeThrow(String method) {
    if (throwOn == method) throw StateError('the tap broke in $method');
  }

  @override
  Object? heard() {
    _maybeThrow('heard');
    return stamp;
  }

  @override
  void pageArrived(
    String strategyId,
    RemotePageSnapshot page,
    Object? heard, {
    required bool throughShareLink,
  }) {
    _maybeThrow('pageArrived');
    order.add(('tap', page));
    pages.add((strategyId, page, heard, throughShareLink));
  }

  @override
  void tapFailed(Object error) => tapFailures.add(error);
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

  /// While set, the parts can't be watched at all.
  bool refuseParts = false;

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

  Object? failReads;

  @override
  Future<ConvexValue> query(String name, ConvexObject args) async {
    reads.add(_key(name, args));
    if (failReads case final error?) throw error;
    return _answer(name, args);
  }

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    final key = _key(name, args);
    if (refuseParts && name != 'page:getSnapshot') {
      return Stream.error(StateError('could not watch $key'));
    }
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
