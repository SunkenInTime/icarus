import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

import 'stamped_over.dart';

final header = {
  'publicId': 'strategy',
  'name': 'Retake B',
  'mapData': 'ascent',
  'revision': 7,
  'createdAt': 1700000000000.0,
  'updatedAt': 1700000500000.0,
  'themeProfileId': 'smoked-ember',
  'themeOverridePalette': null,
  'role': 'editor',
};

final pages = [
  {
    'publicId': 'p-plant',
    'strategyPublicId': 'strategy',
    'name': 'Plant',
    'isAutoNamed': false,
    'sortIndex': 0,
    'isAttack': true,
    'revision': 4,
    'createdAt': 1700000100000.0,
    'updatedAt': 1700000400000.0,
  },
  {
    'publicId': 'p-retake',
    'strategyPublicId': 'strategy',
    'name': 'Page 2',
    'isAutoNamed': true,
    'sortIndex': 1,
    'isAttack': false,
    'revision': 1,
    'createdAt': 1700000200000.0,
    'updatedAt': 1700000200000.0,
  },
  {
    'publicId': 'p-old',
    'strategyPublicId': 'strategy',
    'name': 'Exec',
    'sortIndex': 2,
    'isAttack': true,
    'revision': 2,
    'createdAt': 1700000300000.0,
    'updatedAt': 1700000300000.0,
  },
];

final class _OneState implements ConvexTransport {
  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      Stream.value(switch (name) {
        'strategy:getShell' =>
          ConvexValue.fromDart({'header': header, 'pages': pages}),
        'strategy:getPageList' => ConvexValue.fromDart({
            'header': header,
            'pages': [
              for (final (index, page) in pages.indexed)
                {
                  ...page,
                  'settings': index == 0
                      ? {
                          'agentSize': 40.0,
                          'abilitySize': 30.0,
                          'useNeutralTeamColors': false,
                        }
                      : null,
                  'contentRevision': index + 3,
                  'contentCreatedAt': 1700000000000.0,
                  'contentUpdatedAt': 1700000600000.0,
                },
            ],
          }),
        _ => throw UnimplementedError(name),
      });

  @override
  Stream<List<ConvexValue>> subscribeTogether(
    List<(String, ConvexObject)> queries,
  ) =>
      throw UnimplementedError('subscribeTogether');

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      throw UnimplementedError(name);

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError(name);

  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError(name);
}

Map<String, Object?> seen(RemoteStrategyShell shell) => {
      'header': {
        'publicId': shell.header.publicId,
        'name': shell.header.name,
        'mapData': shell.header.mapData,
        'revision': shell.header.revision,
        'createdAt': shell.header.createdAt,
        'updatedAt': shell.header.updatedAt,
        'themeProfileId': shell.header.themeProfileId,
        'themeOverridePalette': shell.header.themeOverridePalette,
        'role': shell.header.role,
      },
      'pages': [
        for (final page in shell.pages)
          {
            'publicId': page.publicId,
            'strategyPublicId': page.strategyPublicId,
            'name': page.name,
            'isAutoNamed': page.isAutoNamed,
            'sortIndex': page.sortIndex,
            'isAttack': page.isAttack,
            'revision': page.revision,
            'createdAt': page.createdAt,
            'updatedAt': page.updatedAt,
          },
      ],
      'fromCopy': shell.fromCopy,
      'serverAnswer': shell.serverAnswer?.toDart(),
    };

void main() {
  test(
      'the shell the editor gets from a live page list is the one getShell '
      'gives for the same server state: header, pages, order and the answer '
      'the offline copy keeps', () async {
    final server = _OneState();
    final fromShell = await ConvexStrategyRepository(IcarusConvexApi(server))
        .watchShell('strategy')
        .first;
    final fromList = await ConvexStrategyRepository.stamped(StampedOver(server))
        .watchPageListStamped('strategy', accountSubject: 'account-a')
        .first;
    final shell = switch (fromList) {
      StampedValue(:final value) => value.shell,
      StampedError(:final error) => throw error,
    };

    expect(seen(shell), seen(fromShell));
    expect(
      [for (final page in shell.pages) page.publicId],
      ['p-plant', 'p-retake', 'p-old'],
    );
    expect(
      strategyShellFromCopy(shell.serverAnswer!).pages.map((p) => p.name),
      ['Plant', 'Page 2', 'Exec'],
    );
  });
}
