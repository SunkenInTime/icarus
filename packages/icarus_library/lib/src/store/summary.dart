import 'package:collection/collection.dart';

import '../json.dart';
import '../outcome.dart';
import '../payloads.dart';
import '../rows.dart';
import '../wire.dart';

const summaryVersion = 2;

enum Sides { attack, defend, mixed }

final class PageTally {
  PageTally({required this.items, required Map<String, int> agents})
    : agents = Map.unmodifiable(agents);

  static final empty = PageTally(items: 0, agents: const {});

  final int items;
  final Map<String, int> agents;

  PageTally plus(ElementRow row, int sign) {
    final live = switch (row) {
      LiveElement() => true,
      DeletedElement() => false,
      UnreadableElement(:final deleted) => deleted == false,
    };
    if (!live) return this;
    final agent = switch (row) {
      LiveElement(:final payload) when payload.kind == ElementKind.agent =>
        switch (payload.data['type']) {
          final String type => type,
          _ => null,
        },
      _ => null,
    };
    final counts = {...agents};
    if (agent != null) {
      final count = (counts[agent] ?? 0) + sign;
      if (count == 0) {
        counts.remove(agent);
      } else {
        counts[agent] = count;
      }
    }
    return PageTally(items: items + sign, agents: counts);
  }

  Map<String, Object?> toJson() => {
    'items': items,
    'agents': {for (final key in agents.keys.sorted()) key: agents[key]},
  };

  static Decoded<PageTally> decode(Object? json) =>
      JsonFields.read(json, 'page tally', (fields) {
        final items = fields.whole('items');
        final agents = fields.object('agents');
        if (agents.values.any((count) => count is! int)) {
          fields.reject('expected agent counts');
        }
        return () =>
            PageTally(items: items, agents: agents.cast<String, int>());
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
    required List<String> agents,
    required this.itemCount,
    required Map<String, PageTally> tallies,
  }) : agents = List.unmodifiable(agents),
       tallies = Map.unmodifiable(tallies);

  factory StrategySummary.of({
    required ReadableStrategy strategy,
    required Iterable<PageRow> pages,
    required Map<String, PageTally> tallies,
  }) {
    final live = pages.whereType<LivePage>().toList();
    final liveTallies = [
      for (final page in live) tallies[page.publicId] ?? PageTally.empty,
    ];
    final attack = live.where((page) => page.isAttack).length;
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
      agents: {for (final tally in liveTallies) ...tally.agents.keys}.sorted(),
      itemCount: liveTallies.fold(0, (sum, tally) => sum + tally.items),
      tallies: tallies,
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
  final List<String> agents;
  final int itemCount;
  final Map<String, PageTally> tallies;

  StrategySummary after(
    ReadableStrategy strategy,
    Iterable<PageRow> pages,
    Iterable<RowWrite> writes,
  ) {
    final tallies = {...this.tallies};
    for (final write in writes) {
      if (write case RowChanged(before: final ElementRow before)) {
        tallies[before.pagePublicId] =
            (tallies[before.pagePublicId] ?? PageTally.empty).plus(before, -1);
      }
      if (write.after case final ElementRow after) {
        tallies[after.pagePublicId] =
            (tallies[after.pagePublicId] ?? PageTally.empty).plus(after, 1);
      }
    }
    return StrategySummary.of(
      strategy: strategy,
      pages: pages,
      tallies: tallies,
    );
  }

  StrategySummary withHeader(ReadableStrategy strategy) => StrategySummary._(
    publicId: publicId,
    name: strategy.name,
    mapData: strategy.mapData,
    folderPublicId: strategy.folderPublicId,
    createdAt: strategy.createdAt,
    updatedAt: strategy.updatedAt,
    pageCount: pageCount,
    sides: sides,
    agents: agents,
    itemCount: itemCount,
    tallies: tallies,
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
    'agents': agents,
    'itemCount': itemCount,
    'tallies': {
      for (final page in tallies.keys.sorted()) page: tallies[page]!.toJson(),
    },
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
        final itemCount = fields.whole('itemCount');
        final tallies = <String, PageTally>{};
        for (final MapEntry(:key, :value) in fields.object('tallies').entries) {
          switch (PageTally.decode(value)) {
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
          agents: (agents! as List<Object?>).cast<String>(),
          itemCount: itemCount,
          tallies: tallies,
        );
      });

  @override
  bool operator ==(Object other) =>
      other is StrategySummary && sameJson(toJson(), other.toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}
