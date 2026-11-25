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

final class ServerResult {
  ServerResult(this.base, this.cases, {required this.read});

  final ArrivedBase base;
  final List<String> cases;
  final int read;

  bool get stale =>
      cases.contains('stale read') || cases.contains('stale list');
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
  final sortIndexOf = {for (final (i, page) in serverPages.indexed) page: i};
  final revisionOf = {for (final page in serverPages) page: 1};
  final snapshots = <ServerResult>[];
  final generated = <String, int>{};
  final _itemCases = <String, List<String>>{};
  final _pageCases = <String, List<String>>{};
  int reads = 0;
  var _added = 0;

  void _generated(String what, {HeldItem? item, String? page}) {
    _made(what);
    if (item != null) (_itemCases[item.id] ??= []).add(what);
    if (page != null) (_pageCases[page] ??= []).add(what);
  }

  void change() {
    final row = held[random.nextInt(held.length)];
    switch (random.nextInt(9)) {
      case 0 || 1:
        row
          ..x = random.nextDouble() * 1000
          ..revision += 1;
        _generated('payload changed', item: row);
      case 2:
        row
          ..page = serverPages
              .where((page) => page != row.page)
              .toList()[random.nextInt(2)]
          ..revision += 1;
        _generated('moved between pages', item: row);
      case 3:
        final deleted = [
          for (final each in held)
            if (!each.live) each,
        ];
        final toggled = deleted.isNotEmpty && random.nextBool()
            ? deleted[random.nextInt(deleted.length)]
            : row;
        toggled
          ..live = !toggled.live
          ..revision += 1;
        _generated(toggled.live ? 'restored' : 'deleted', item: toggled);
      case 4:
        row
          ..life += 1000
          ..x = random.nextDouble() * 1000;
        _generated('life changed at the same revision', item: row);
      case 5:
        row
          ..sortIndex = random.nextInt(20)
          ..revision += 1;
        _generated('reordered', item: row);
      case 6:
        final page = serverPages[random.nextInt(serverPages.length)];
        final trashing = !trashed.contains(page);
        final live = [
          for (final each in serverPages)
            if (!trashed.contains(each) && each != page) each,
        ]..sort((a, b) => sortIndexOf[a]!.compareTo(sortIndexOf[b]!));
        if (trashing) {
          trashed.add(page);
        } else {
          trashed.remove(page);
          live.insert(sortIndexOf[page]!.clamp(0, live.length), page);
        }
        for (final (index, each) in live.indexed) {
          if (sortIndexOf[each] != index) {
            sortIndexOf[each] = index;
            revisionOf[each] = revisionOf[each]! + 1;
          }
        }
        _generated(trashing ? 'page trashed' : 'page restored', page: page);
      case 7:
        final deleted = [
          for (final each in held)
            if (!each.live) each,
        ];
        if (deleted.isEmpty || random.nextInt(3) != 0) break;
        final purged = deleted[random.nextInt(deleted.length)];
        held.remove(purged);
        _itemCases.remove(purged.id);
        _generated('purged', page: purged.page);
      case _:
        final id = 'added-${_added++}';
        final item = HeldItem(
          id,
          lineup: random.nextInt(4) == 0,
          page: serverPages[random.nextInt(serverPages.length)],
          life: fixtureLife + 100 + _added,
        );
        held.add(item);
        _generated('added', item: item);
    }
  }

  List<String> get livePages => [
    for (final page in serverPages)
      if (!trashed.contains(page)) page,
  ]..sort((a, b) => sortIndexOf[a]!.compareTo(sortIndexOf[b]!));

  LivePage pageRow(String page) => LivePage(
    publicId: page,
    strategyPublicId: strategyId,
    name: page,
    sortIndex: sortIndexOf[page]!,
    isAttack: true,
    revision: revisionOf[page]!,
    unknownFields: jsonObject(const {'createdAt': fixtureLife}),
  );

  StrategyRowSet rows() => strategyRows(
    pages: [for (final page in livePages) pageRow(page)],
    elements: [
      for (final item in held)
        if (!trashed.contains(item.page))
          if (item.row case final ElementRow row) row,
    ],
    lineupGroups: [
      for (final item in held)
        if (!trashed.contains(item.page))
          if (item.row case final LineupGroupRow row) row,
    ],
  );

  List<String> _deliveredPage(String page) => [...?_pageCases.remove(page)];

  void _made(String what) => generated[what] = (generated[what] ?? 0) + 1;

  ServerResult? _stale(bool Function(ArrivedBase base) kind, String what) {
    final older = [
      for (final each in snapshots)
        if (kind(each.base)) each,
    ];
    if (older.isEmpty) return null;
    final stale = older[random.nextInt(older.length)];
    _made(what);
    return ServerResult(stale.base, [what], read: stale.read);
  }

  ServerResult pageList() {
    if (random.nextInt(4) == 0) {
      if (_stale((base) => base is HeaderRead, 'stale list')
          case final stale?) {
        return stale;
      }
    }
    _made('page list');
    final result = ServerResult(
      HeaderRead(
        strategy: rows().strategy,
        pages: rows().pages.toList(),
        settings: rows().settings.toList(),
      ),
      ['page list', for (final page in serverPages) ..._deliveredPage(page)],
      read: ++reads,
    );
    snapshots.add(result);
    return result;
  }

  ServerResult read() {
    if (random.nextInt(6) == 0) {
      if (_stale((base) => base is! HeaderRead, 'stale read')
          case final stale?) {
        return stale;
      }
    }
    final page = serverPages[random.nextInt(serverPages.length)];
    if (trashed.contains(page)) {
      _made('trashed page read');
      return ServerResult(PageGone(page), [
        'trashed page read',
        ..._deliveredPage(page),
      ], read: ++reads);
    }
    final leaving = random.nextInt(5) == 0;
    final included = [
      for (final each in held)
        if (each.page == page && !(leaving && random.nextBool())) each,
    ];
    if (leaving) {
      _made('rows left out of a read');
    }
    final rows = [for (final item in included) item.row];
    final result = ServerResult(
      PageRead(
        page: pageRow(page),
        elements: [
          for (final row in rows)
            if (row is ElementRow) row,
        ],
        lineupGroups: [
          for (final row in rows)
            if (row is LineupGroupRow) row,
        ],
      ),
      [
        if (leaving) 'rows left out of a read',
        ..._deliveredPage(page),
        for (final item in included) ...?_itemCases.remove(item.id),
      ],
      read: ++reads,
    );
    snapshots.add(result);
    return result;
  }
}
