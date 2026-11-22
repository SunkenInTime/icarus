import 'package:collection/collection.dart';

import '../json.dart';
import '../outcome.dart';
import '../payloads.dart';
import '../rows.dart';
import '../wire.dart';
import '../cloud/codec.dart';
import '../cloud/queue.dart';
import '../cloud/sync.dart';

const summaryVersion = 6;

enum Sides { attack, defend, mixed }

sealed class SummarySync {
  const SummarySync();
}

final class KeptHere extends SummarySync {
  const KeptHere();
}

final class KeptInCloud extends SummarySync {
  const KeptInCloud(this.tally);

  final Tally tally;
}

final class CloudUnverified extends SummarySync {
  const CloudUnverified();
}

sealed class Readability {
  const Readability();
}

final class AllReadable extends Readability {
  const AllReadable();
}

final class SomeUnreadable extends Readability {
  const SomeUnreadable({required this.damaged, required this.newer});

  final int damaged;
  final int newer;
}

int _byPlaceThenId((int, String) a, (int, String) b) =>
    a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2);

List<String> _agentsInReadingOrder(
  Iterable<ElementRow> elements,
  Iterable<LineupGroupRow> lineupGroups,
) {
  final placed = [
    for (final row in elements)
      if (row case LiveElement(
        :final payload,
        :final sortIndex,
        :final publicId,
      ) when payload.kind == ElementKind.agent)
        if (payload.data.raw['type'] case final String type)
          (place: (sortIndex, publicId), type: type),
  ]..sort((a, b) => _byPlaceThenId(a.place, b.place));
  final groups = [
    for (final row in lineupGroups)
      if (row case LiveLineupGroup(
        :final payload,
        :final sortIndex,
        :final publicId,
      ))
        (place: (sortIndex, publicId), origins: payload.data.raw['origins']),
  ]..sort((a, b) => _byPlaceThenId(a.place, b.place));
  return {
    for (final agent in placed) agent.type,
    for (final group in groups)
      if (group.origins case final List<Object?> origins)
        for (final origin in origins)
          if (origin case {'agent': {'type': final String type}}) type,
  }.toList();
}

final class PageTally {
  PageTally({
    required this.items,
    required Map<String, int> agents,
    required this.damaged,
    required this.newer,
    List<String> order = const [],
  }) : agents = Map.unmodifiable(agents),
       order = List.unmodifiable(order);

  factory PageTally.count({
    required Iterable<ElementRow> elements,
    required Iterable<LineupGroupRow> lineupGroups,
    int damaged = 0,
    int newer = 0,
  }) {
    var tally = empty.plusDamaged(damaged).plusNewer(newer);
    for (final row in elements) {
      tally = tally._plus(row);
    }
    for (final row in lineupGroups) {
      if (row is UnreadableLineupGroup) tally = tally.plusDamaged(1);
    }
    return tally._with(order: _agentsInReadingOrder(elements, lineupGroups));
  }

  static final empty = PageTally(
    items: 0,
    agents: const {},
    damaged: 0,
    newer: 0,
  );

  final int items;
  final Map<String, int> agents;
  final int damaged;
  final int newer;
  final List<String> order;

  PageTally _with({
    int? items,
    Map<String, int>? agents,
    int damaged = 0,
    int newer = 0,
    List<String>? order,
  }) => PageTally(
    items: items ?? this.items,
    agents: agents ?? this.agents,
    damaged: this.damaged + damaged,
    newer: this.newer + newer,
    order: order ?? this.order,
  );

  PageTally plusDamaged(int count) => _with(damaged: count);

  PageTally plusNewer(int count) => _with(newer: count);

  PageTally _plus(ElementRow row) {
    final counted = switch (row) {
      UnreadableElement(reason: Damaged()) => _with(damaged: 1),
      UnreadableElement(reason: FromNewerBuild()) => _with(newer: 1),
      LiveElement() || DeletedElement() => this,
    };
    final live = switch (row) {
      LiveElement() => true,
      DeletedElement() => false,
      UnreadableElement(:final deleted) => deleted == false,
    };
    if (!live) return counted;
    final agent = switch (row) {
      LiveElement(:final payload) when payload.kind == ElementKind.agent =>
        switch (payload.data.raw['type']) {
          final String type => type,
          _ => null,
        },
      _ => null,
    };
    return counted._with(
      items: items + 1,
      agents: agent == null
          ? agents
          : {...agents, agent: (agents[agent] ?? 0) + 1},
    );
  }

  Map<String, Object?> toJson() => {
    'items': items,
    'agents': {for (final key in agents.keys.sorted()) key: agents[key]},
    'damaged': damaged,
    'newer': newer,
    'order': order,
  };

  static Decoded<PageTally> decode(Object? json) =>
      JsonFields.read(json, 'page tally', (fields) {
        final items = fields.whole('items');
        final damaged = fields.whole('damaged');
        final newer = fields.whole('newer');
        final agents = fields.object('agents').raw;
        if (!agents.values.every(isSafeWhole)) {
          fields.reject('expected agent counts');
        }
        final order = fields.json['order'];
        if (order is! List<Object?> || order.any((type) => type is! String)) {
          fields.reject('expected the agents in order');
        }
        return () => PageTally(
          items: items,
          agents: {
            for (final MapEntry(:key, :value) in agents.entries)
              key: (value as num).toInt(),
          },
          damaged: damaged,
          newer: newer,
          order: (order! as List<Object?>).cast<String>(),
        );
      });

  @override
  bool operator ==(Object other) =>
      other is PageTally && sameJson(toJson(), other.toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}

final class StrategySummary {
  StrategySummary._({
    required this.publicId,
    required this.name,
    required this.mapData,
    required this.folderPublicId,
    required this.createdAt,
    required this.updatedAt,
    required this.pageCount,
    required this.sides,
    required this.firstPageIsAttack,
    required List<String> agents,
    required List<String> agentsInOrder,
    required this.itemCount,
    required this.readability,
    required this.elsewhere,
    required Map<String, PageTally> tallies,
    required this.sync,
  }) : agents = List.unmodifiable(agents),
       agentsInOrder = List.unmodifiable(agentsInOrder),
       tallies = Map.unmodifiable(tallies);

  factory StrategySummary.of({
    required ReadableStrategy strategy,
    required Iterable<PageRow> pages,
    required Iterable<PageSettingsRow> settings,
    required Map<String, PageTally> tallies,
    required PageTally elsewhere,
    SummarySync sync = const KeptHere(),
  }) {
    final pageIds = {for (final page in pages) page.publicId};
    tallies = {
      for (final MapEntry(:key, :value) in tallies.entries)
        if (pageIds.contains(key) && value != PageTally.empty) key: value,
    };
    final damaged =
        tallies.values.fold(0, (sum, tally) => sum + tally.damaged) +
        pages.whereType<UnreadablePage>().length +
        settings.whereType<UnreadablePageSettings>().length +
        elsewhere.damaged;
    final newer =
        tallies.values.fold(0, (sum, tally) => sum + tally.newer) +
        elsewhere.newer;
    final live = pages.whereType<LivePage>().toList();
    final liveTallies = [
      for (final page in live) tallies[page.publicId] ?? PageTally.empty,
    ];
    final attack = live.where((page) => page.isAttack).length;
    final inOrder = [...live]
      ..sort(
        (a, b) => a.sortIndex != b.sortIndex
            ? a.sortIndex.compareTo(b.sortIndex)
            : a.publicId.compareTo(b.publicId),
      );
    return StrategySummary._(
      publicId: strategy.publicId,
      name: strategy.name,
      mapData: strategy.mapData,
      folderPublicId: strategy.folderPublicId,
      createdAt: strategy.createdAt,
      updatedAt: strategy.updatedAt,
      pageCount: live.length,
      sides: switch (attack) {
        0 => Sides.defend,
        _ when attack == live.length => Sides.attack,
        _ => Sides.mixed,
      },
      firstPageIsAttack: inOrder.firstOrNull?.isAttack,
      agents: {for (final tally in liveTallies) ...tally.agents.keys}.sorted(),
      agentsInOrder: {
        for (final page in inOrder) ...?tallies[page.publicId]?.order,
      }.toList(),
      itemCount: liveTallies.fold(0, (sum, tally) => sum + tally.items),
      readability: damaged == 0 && newer == 0
          ? const AllReadable()
          : SomeUnreadable(damaged: damaged, newer: newer),
      elsewhere: elsewhere,
      tallies: tallies,
      sync: sync,
    );
  }

  final String publicId;
  final String name;
  final String mapData;
  final String? folderPublicId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int pageCount;
  final Sides sides;
  final bool? firstPageIsAttack;
  final List<String> agents;
  final List<String> agentsInOrder;
  final int itemCount;
  final Readability readability;
  final PageTally elsewhere;
  final Map<String, PageTally> tallies;
  final SummarySync sync;

  StrategySummary withSync(SummarySync sync) => StrategySummary._(
    publicId: publicId,
    name: name,
    mapData: mapData,
    folderPublicId: folderPublicId,
    createdAt: createdAt,
    updatedAt: updatedAt,
    pageCount: pageCount,
    sides: sides,
    firstPageIsAttack: firstPageIsAttack,
    agents: agents,
    agentsInOrder: agentsInOrder,
    itemCount: itemCount,
    readability: readability,
    elsewhere: elsewhere,
    tallies: tallies,
    sync: sync,
  );

  static Set<String> pagesCounted(Iterable<RowWrite> writes) => {
    for (final write in writes) ...[
      if (write case RowChanged(before: ElementRow(:final pagePublicId)))
        pagePublicId,
      if (write case RowChanged(before: LineupGroupRow(:final pagePublicId)))
        pagePublicId,
      if (write.after case ElementRow(:final pagePublicId)) pagePublicId,
      if (write.after case LineupGroupRow(:final pagePublicId)) pagePublicId,
    ],
  };

  StrategySummary after(
    ReadableStrategy strategy,
    Iterable<PageRow> pages,
    Iterable<PageSettingsRow> settings,
    Map<String, PageTally> recounted,
  ) => StrategySummary.of(
    strategy: strategy,
    pages: pages,
    settings: settings,
    tallies: {...tallies, ...recounted},
    elsewhere: elsewhere,
    sync: sync,
  );

  StrategySummary withHeader(ReadableStrategy strategy) => StrategySummary._(
    publicId: publicId,
    name: strategy.name,
    mapData: strategy.mapData,
    folderPublicId: strategy.folderPublicId,
    createdAt: strategy.createdAt,
    updatedAt: strategy.updatedAt,
    pageCount: pageCount,
    sides: sides,
    firstPageIsAttack: firstPageIsAttack,
    agents: agents,
    agentsInOrder: agentsInOrder,
    itemCount: itemCount,
    readability: readability,
    elsewhere: elsewhere,
    tallies: tallies,
    sync: sync,
  );

  Map<String, Object?> toJson() => {
    'summaryVersion': summaryVersion,
    'publicId': publicId,
    'name': name,
    'mapData': mapData,
    if (folderPublicId != null) 'folderPublicId': folderPublicId,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'pageCount': pageCount,
    'sides': sides.name,
    'firstPageIsAttack': ?firstPageIsAttack,
    'agents': agents,
    'agentsInOrder': agentsInOrder,
    'itemCount': itemCount,
    'damagedRows': switch (readability) {
      AllReadable() => 0,
      SomeUnreadable(:final damaged) => damaged,
    },
    'newerRows': switch (readability) {
      AllReadable() => 0,
      SomeUnreadable(:final newer) => newer,
    },
    'elsewhere': elsewhere.toJson(),
    'tallies': {
      for (final page in tallies.keys.sorted()) page: tallies[page]!.toJson(),
    },
    if (sync case KeptInCloud(:final tally))
      'cloud': {'tally': tally.toJson(), 'rowsVersion': cloudRowVersion},
    if (sync case CloudUnverified())
      'cloud': {'unverified': true, 'rowsVersion': cloudRowVersion},
  };

  static Decoded<StrategySummary> decode(Object? json) =>
      JsonFields.read(json, 'strategy summary', (fields) {
        if (fields.whole('summaryVersion') != summaryVersion) {
          fields.reject('a summary version this build does not read');
        }
        final publicId = fields.string('publicId');
        final name = fields.string('name');
        final mapData = fields.string('mapData');
        final folderPublicId = fields.optionalString('folderPublicId');
        final createdAt = fields.time('createdAt');
        final updatedAt = fields.time('updatedAt');
        final pageCount = fields.whole('pageCount');
        final sides = Sides.values.asNameMap()[fields.json['sides']];
        if (sides == null) fields.reject('expected sides');
        final agents = fields.json['agents'];
        if (agents is! List<Object?> || agents.any((a) => a is! String)) {
          fields.reject('expected agents');
        }
        final agentsInOrder = fields.json['agentsInOrder'];
        if (agentsInOrder is! List<Object?> ||
            agentsInOrder.any((a) => a is! String)) {
          fields.reject('expected agents in order');
        }
        final firstPageIsAttack = fields.json['firstPageIsAttack'];
        if (fields.json.containsKey('firstPageIsAttack') &&
            firstPageIsAttack is! bool) {
          fields.reject('expected the first page\'s side');
        }
        final itemCount = fields.whole('itemCount');
        final damaged = fields.whole('damagedRows');
        final newer = fields.whole('newerRows');
        final elsewhere = fields.decoded('elsewhere', PageTally.decode);
        final cloud = fields.optionalDecoded('cloud', _cloudSync);
        final tallies = <String, PageTally>{};
        for (final MapEntry(:key, :value)
            in fields.object('tallies').raw.entries) {
          switch (PageTally.decode(adoptJson(value))) {
            case Read(value: final tally):
              tallies[key] = tally;
            case CouldNotRead(:final problem):
              fields.reject(problem);
          }
        }
        return () => StrategySummary._(
          publicId: publicId,
          name: name,
          mapData: mapData,
          folderPublicId: folderPublicId,
          createdAt: createdAt,
          updatedAt: updatedAt,
          pageCount: pageCount,
          sides: sides!,
          firstPageIsAttack: firstPageIsAttack as bool?,
          agents: (agents! as List<Object?>).cast<String>(),
          agentsInOrder: (agentsInOrder! as List<Object?>).cast<String>(),
          itemCount: itemCount,
          readability: damaged == 0 && newer == 0
              ? const AllReadable()
              : SomeUnreadable(damaged: damaged, newer: newer),
          elsewhere: elsewhere!,
          tallies: tallies,
          sync: cloud ?? const KeptHere(),
        );
      });

  static Decoded<KeptInCloud> _cloudSync(Object? json) =>
      JsonFields.read(json, 'cloud sync', (fields) {
        final version = fields.whole('rowsVersion');
        if (version > cloudRowVersion) {
          return () =>
              KeptInCloud(Tally(standing: Standing.held, unreadable: 1));
        }
        final tally = fields.decoded('tally', Tally.decode);
        return () => KeptInCloud(tally!);
      });

  @override
  bool operator ==(Object other) =>
      other is StrategySummary && sameJson(toJson(), other.toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}
