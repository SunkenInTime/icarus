import 'dart:math';

import 'package:icarus_library/icarus_library.dart';

import 'support.dart';

const serverPages = ['page-a', 'page-b', 'page-c'];

final class HeldItem {
  HeldItem(
    this.id, {
    required this.lineup,
    required this.page,
    required this.life,
  });

  final String id;
  final bool lineup;
  String page;
  int life;
  int revision = 1;
  bool live = true;
  int sortIndex = 0;
  double x = 0;

  Row get row {
    final fields = jsonObject({'createdAt': life});
    if (lineup) {
      final payload = LineupGroupPayload(
        payloadVersion: 1,
        data: {
          'id': id,
          'origins': [
            {
              'id': '$id-origin',
              'agent': {'type': 'sova'},
            },
          ],
          'landings': [
            {
              'id': '$id-landing',
              'ability': {'type': 'recon'},
            },
          ],
          'links': [
            {
              'id': '$id-link',
              'originId': '$id-origin',
              'landingId': '$id-landing',
              'notes': 'x $x',
            },
          ],
        },
      );
      return live
          ? LiveLineupGroup(
              publicId: id,
              strategyPublicId: strategyId,
              pagePublicId: page,
              payload: payload,
              sortIndex: sortIndex,
              revision: revision,
              unknownFields: fields,
            )
          : DeletedLineupGroup(
              publicId: id,
              strategyPublicId: strategyId,
              pagePublicId: page,
              payload: payload,
              sortIndex: sortIndex,
              revision: revision,
              unknownFields: fields,
            );
    }
    final payload = agentPayload(id, {
      'position': {'dx': x, 'dy': 3.5},
    });
    return live
        ? LiveElement(
            publicId: id,
            pagePublicId: page,
            payload: payload,
            sortIndex: sortIndex,
            revision: revision,
            unknownFields: fields,
          )
        : DeletedElement(
            publicId: id,
            pagePublicId: page,
            payload: payload,
            sortIndex: sortIndex,
            revision: revision,
            unknownFields: fields,
          );
  }
}

final class RandomServer {
  RandomServer(this.random) {
    for (var i = 0; i < 12; i++) {
      held.add(
        HeldItem(
          'row-$i',
          lineup: i % 4 == 3,
          page: serverPages[i % serverPages.length],
          life: fixtureLife + i,
        ),
      );
    }
  }

  final Random random;
  final held = <HeldItem>[];
  final trashed = <String>{};
  final pageRevisions = {for (final page in serverPages) page: 1};
  final snapshots = <PageRead>[];
  final reached = <String, int>{};

  void count(String what) => reached[what] = (reached[what] ?? 0) + 1;

  void change() {
    final row = held[random.nextInt(held.length)];
    switch (random.nextInt(9)) {
      case 0 || 1:
        row
          ..x = random.nextDouble() * 1000
          ..revision += 1;
        count('payload changed');
      case 2:
        row
          ..page = serverPages
              .where((page) => page != row.page)
              .toList()[random.nextInt(2)]
          ..revision += 1;
        count('moved between pages');
      case 3:
        row
          ..live = !row.live
          ..revision += 1;
        count(row.live ? 'restored' : 'deleted');
      case 4:
        row
          ..life += 1000
          ..x = random.nextDouble() * 1000;
        count('life changed at the same revision');
      case 5:
        row
          ..sortIndex = random.nextInt(20)
          ..revision += 1;
        count('reordered');
      case 6:
        final page = serverPages[random.nextInt(serverPages.length)];
        if (!trashed.remove(page)) trashed.add(page);
        pageRevisions[page] = pageRevisions[page]! + 1;
        count('page trashed or restored');
      case _:
        break;
    }
  }

  PageRow pageRow(String page) => trashed.contains(page)
      ? PendingTrashedPage(
          publicId: page,
          strategyPublicId: strategyId,
          name: page,
          sortIndex: serverPages.indexOf(page),
          isAttack: true,
          revision: pageRevisions[page]!,
          unknownFields: jsonObject(const {'createdAt': fixtureLife}),
        )
      : LivePage(
          publicId: page,
          strategyPublicId: strategyId,
          name: page,
          sortIndex: serverPages.indexOf(page),
          isAttack: true,
          revision: pageRevisions[page]!,
          unknownFields: jsonObject(const {'createdAt': fixtureLife}),
        );

  StrategyRowSet rows() => strategyRows(
    pages: [for (final page in serverPages) pageRow(page)],
    elements: [
      for (final item in held)
        if (item.row case final ElementRow row) row,
    ],
    lineupGroups: [
      for (final item in held)
        if (item.row case final LineupGroupRow row) row,
    ],
  );

  PageRead read() {
    if (snapshots.isNotEmpty && random.nextInt(6) == 0) {
      count('stale read');
      return snapshots[random.nextInt(snapshots.length)];
    }
    final page = serverPages[random.nextInt(serverPages.length)];
    final leaving = random.nextInt(5) == 0;
    final rows = [
      for (final each in held)
        if (each.page == page && !(leaving && random.nextBool())) each.row,
    ];
    if (leaving) count('rows left out of a read');
    final read = PageRead(
      page: pageRow(page),
      elements: [
        for (final row in rows)
          if (row is ElementRow) row,
      ],
      lineupGroups: [
        for (final row in rows)
          if (row is LineupGroupRow) row,
      ],
    );
    snapshots.add(read);
    return read;
  }
}
