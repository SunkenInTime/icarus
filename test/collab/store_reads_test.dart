import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/convex_error_codes.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus_library/icarus_library.dart';

import 'strategy_copy_fixtures.dart';

const _stamp = ResultStamp(
  client: 2,
  connection: 3,
  snapshot: 41,
  serverTime: 1795435204780123456,
);

const _point = ResultPoint(
  client: 2,
  connection: 3,
  snapshot: 41,
  serverTime: 1795435204780123456,
);

final class _Reading implements StampedConvexTransport {
  final queries = <(String, Map<String, Object?>)>[];
  Object? Function(String name)? answer;

  @override
  Future<Stamped<ConvexValue>> queryStamped(
    String name,
    ConvexObject args,
  ) async {
    queries.add((name, args.toDart()));
    try {
      return StampedValue(ConvexValue.fromDart(answer!(name)), _stamp);
    } on ConvexFunctionException catch (error) {
      return StampedError(
        ConvexTransportError(rawCode: error.rawCode, message: error.message),
        _stamp,
      );
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const strategy = 'strategy';
final owner = Account('account-a');

Map<String, Object?> listAnswer({String role = 'owner'}) => {
      'header': {...headerRow(), 'role': role},
      'pages': [
        {
          ...pageRow('p1'),
          'settings': null,
          'contentRevision': 1,
          'contentCreatedAt': 1.0,
          'contentUpdatedAt': 1.0,
        },
      ],
    };

Map<String, Object?> pageAnswer() => {
      'page': pageRow('p1'),
      'content': contentRow(),
      'elements': [agentRow('a1', 'p1', revision: 4)],
      'lineups': <Object?>[],
      'assets': <Object?>[],
    };

ConvexFunctionException refusal(String code) => ConvexFunctionException(
      code: ConvexErrorCode.fromWireName(code),
      rawCode: code,
      message: 'refused',
    );

void main() {
  late _Reading transport;
  late StoreReads reads;

  setUp(() {
    transport = _Reading();
    reads = storeReadsOver(
      ConvexStrategyRepository.stamped(transport),
      canRead: appCanRead,
    );
  });

  test(
      'the page list is read once, naming the account, and comes back as the '
      'store\'s header with the caller\'s role', () async {
    transport.answer = (_) => listAnswer();
    final outcome = await reads.pageList(
      strategyPublicId: strategy,
      account: owner,
    );
    final (name, args) = transport.queries.single;
    expect(name, 'strategy:getPageList');
    expect(args['accountSubject'], 'account-a');
    expect(args['strategyPublicId'], strategy);
    expect(args['clientProtocolVersion'], isNotNull);
    final answered = outcome as StoreReadAnswered;
    expect(answered.point, _point);
    expect(answered.role, StoreReadRole.owner);
    expect(answered.role!.edits, isTrue);
    final header = answered.base as HeaderRead;
    expect([for (final page in header.pages) page.publicId], ['p1']);
    expect(header.role, const RoleKnown(CloudRole.owner));
  });

  test(
      'the page list asks for the trash and carries each trashed page as the '
      'store\'s confirmed trashed row', () async {
    transport.answer = (_) => {
          ...listAnswer(),
          'trashedPages': [
            {
              'createdAt': 1795828106631,
              'deletedAt': 1795828112278,
              'deletedBy': {'name': 'jules'},
              'isAttack': false,
              'isAutoNamed': false,
              'name': 'Page 3',
              'publicId': 'p3',
              'restorableUntil': 1798420112278,
              'revision': 2,
              'sortIndex': 1,
              'strategyPublicId': strategy,
            },
            {
              'createdAt': 1795828105415,
              'deletedAt': 1795828111096,
              'deletedBy': 'you',
              'isAttack': false,
              'isAutoNamed': false,
              'name': 'Page 2',
              'publicId': 'p2',
              'restorableUntil': 1798420111096,
              'revision': 1,
              'sortIndex': 1,
              'strategyPublicId': strategy,
            },
          ],
        };
    final outcome = await reads.pageList(
      strategyPublicId: strategy,
      account: owner,
    );
    expect(transport.queries.single.$2['includeTrashed'], isTrue);
    final header = (outcome as StoreReadAnswered).base as HeaderRead;
    expect(
        [for (final page in header.pages) page.publicId], ['p1', 'p3', 'p2']);
    final trashed = [
      for (final page in header.pages)
        if (page case final ConfirmedTrashedPage trashed) trashed,
    ];
    expect([
      for (final page in trashed) page.deletedBy
    ], const [
      DeletedByName('jules'),
      DeletedByYou(),
    ]);
    expect(trashed.first.sortIndex, 1);
    expect(trashed.first.revision, 2);
  });

  test('a viewer\'s page list says the caller cannot edit', () async {
    transport.answer = (_) => listAnswer(role: 'viewer');
    final outcome = await reads.pageList(
      strategyPublicId: strategy,
      account: owner,
    );
    expect((outcome as StoreReadAnswered).role!.edits, isFalse);
    expect(
      (outcome.base as HeaderRead).role,
      const RoleKnown(CloudRole.viewer),
    );
  });

  test('a page carries every picture the server listed for it, as listed',
      () async {
    transport.answer = (_) => {
          ...pageAnswer(),
          'assets': [assetRow('pic-1')],
        };
    final outcome = await reads.page(
      strategyPublicId: strategy,
      pagePublicId: 'p1',
      account: owner,
    );
    final page = (outcome as StoreReadAnswered).base as PageRead;
    expect(page.pictures, {
      'pic-1': const PictureAsset(
        provider: 'r2',
        uploadStatus: 'active',
        fileExtension: '.png',
        mimeType: 'image/png',
        url: 'https://images.example/pic-1.png',
      ),
    });
  });

  test(
      'a page is read once, naming the account, and comes back as the '
      'store\'s page with its rows', () async {
    transport.answer = (_) => pageAnswer();
    final outcome = await reads.page(
      strategyPublicId: strategy,
      pagePublicId: 'p1',
      account: owner,
    );
    final (name, args) = transport.queries.single;
    expect(name, 'page:getSnapshot');
    expect(args['accountSubject'], 'account-a');
    expect(args['pagePublicId'], 'p1');
    expect(args['acceptsPictureIds'], true);
    expect(args['elementFieldLevel'], isNotNull);
    final answered = outcome as StoreReadAnswered;
    expect(answered.role, isNull);
    final page = answered.base as PageRead;
    expect(page.page.publicId, 'p1');
    expect(page.pictures, isEmpty);
    expect(
      [for (final row in page.elements) (row as LiveElement).revision],
      [4],
    );
  });

  test(
      'a row this build cannot read comes back kept whole as unreadable, not '
      'dropped', () async {
    transport.answer = (_) => {
          ...pageAnswer(),
          'elements': [
            {
              ...agentRow('a1', 'p1'),
              'payload': {
                ...(agentRow('a1', 'p1')['payload']! as Map),
                'payloadVersion': 999,
              },
            },
          ],
        };
    final outcome = await reads.page(
      strategyPublicId: strategy,
      pagePublicId: 'p1',
      account: owner,
    );
    final page = (outcome as StoreReadAnswered).base as PageRead;
    expect(page.elements.single, isA<UnreadableElement>());
  });

  test('each refusal of a read has one meaning to the store', () async {
    Future<StoreReadOutcome> list(String code) {
      transport.answer = (_) => throw refusal(code);
      return reads.pageList(strategyPublicId: strategy, account: owner);
    }

    Future<StoreReadOutcome> page(String code) {
      transport.answer = (_) => throw refusal(code);
      return reads.page(
        strategyPublicId: strategy,
        pagePublicId: 'p1',
        account: owner,
      );
    }

    Matcher refused(StoreReadRefusal refusal) => isA<StoreReadRefused>()
        .having((outcome) => outcome.refusal, 'refusal', refusal);
    Matcher lost(TransportFailure failure) => isA<StoreReadLost>()
        .having((outcome) => outcome.failure, 'failure', failure);
    Matcher gone(Matcher base) => isA<StoreReadAnswered>()
        .having((outcome) => outcome.base, 'base', base)
        .having((outcome) => outcome.point, 'point', _point);

    expect(
      await list('ACCOUNT_MISMATCH'),
      refused(StoreReadRefusal.accountMismatch),
    );
    expect(
      await list('UNAUTHENTICATED'),
      refused(StoreReadRefusal.unauthenticated),
    );
    expect(await list('FORBIDDEN'), refused(StoreReadRefusal.forbidden));
    expect(
      await list('CLIENT_UPGRADE_REQUIRED'),
      refused(StoreReadRefusal.upgradeRequired),
    );
    expect(await list('NOT_FOUND'), gone(isA<StrategyGone>()));
    expect(
      await page('NOT_FOUND'),
      gone(isA<PageGone>().having((gone) => gone.pagePublicId, 'page', 'p1')),
    );
    expect(await page('PAGE_STRATEGY_MISMATCH'), gone(isA<PageGone>()));
    expect(await page('FORBIDDEN'), refused(StoreReadRefusal.forbidden));
    expect(await list('RATE_LIMITED'), lost(TransportFailure.network));
    expect(
      storeReadOutcomeOfError(
        TimeoutException('slow'),
        gone: const StrategyGone(),
        point: null,
      ),
      lost(TransportFailure.timeout),
    );
    expect(
      storeReadOutcomeOfError(
        const FormatException('bad'),
        gone: const StrategyGone(),
        point: null,
      ),
      lost(TransportFailure.malformedAnswer),
    );
  });
}
