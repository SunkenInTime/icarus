import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus/library_store/store_pictures.dart';
import 'package:icarus_library/icarus_library.dart';

import '../collab/strategy_copy_fixtures.dart';

final class _Answering implements StampedConvexTransport {
  _Answering(this.answer);

  final Map<String, Object?> answer;

  @override
  Future<Stamped<ConvexValue>> queryStamped(
    String name,
    ConvexObject args,
  ) async =>
      StampedValue(
        ConvexValue.fromDart(answer),
        const ResultStamp(client: 1, connection: 1, snapshot: 1, serverTime: 1),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<PageRead> _read(Map<String, Object?> answer) async {
  final reads = storeReadsOver(
    ConvexStrategyRepository.stamped(_Answering(answer)),
    canRead: appCanRead,
  );
  final outcome = await reads.page(
    strategyPublicId: 'strategy',
    pagePublicId: 'p1',
    account: Account('account-a'),
  );
  return (outcome as StoreReadAnswered).base as PageRead;
}

PageContent _stored(PageRead read, PageContentState content) => PageContent(
      strategyLife: 1,
      page: read.page,
      settings: const NoSettingsStored(),
      elements: read.elements,
      lineupGroups: read.lineupGroups,
      unknownKinds: const [],
      unplaced: const [],
      foreignNames: const [],
      content: content,
    );

void main() {
  test(
      'a stored page lists the pictures its images and lineups refer to, and '
      'which of them the server described', () async {
    final read = await _read({
      'page': pageRow('p1'),
      'content': contentRow(),
      'elements': [
        agentRow('a1', 'p1'),
        imageRow('i1', 'p1', 'pic-1'),
        imageRow('i2', 'p1', 'pic-2'),
      ],
      'lineups': [lineupRow('g1', 'p1', 'pic-3')],
      'assets': [assetRow('pic-1')],
    });
    final pictures = picturesOf(
      _stored(read, ContentShown(pictures: read.pictures)),
    ) as PicturesOnPage;
    expect(pictures.referenced, {'pic-1', 'pic-2', 'pic-3'});
    expect(pictures.known.keys, ['pic-1']);
    expect(pictures.unknown, {'pic-2', 'pic-3'});
  });

  test('a page whose content was not read lists nothing', () async {
    final read = await _read({
      'page': pageRow('p1'),
      'content': contentRow(),
      'elements': [imageRow('i1', 'p1', 'pic-1')],
      'lineups': <Object?>[],
      'assets': [assetRow('pic-1')],
    });
    expect(
      picturesOf(_stored(read, const ContentNotRead())),
      isA<PicturesNotKnown>().having(
        (known) => known.why,
        'why',
        PicturesNotListed.contentNotRead,
      ),
    );
  });
}
