import 'package:collection/collection.dart';

import '../json.dart';
import '../outcome.dart';
import '../payloads.dart';
import '../rows.dart';
import '../wire.dart';

const summaryVersion = 5;

enum Sides { attack, defend, mixed }

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

final class PageTally {
  PageTally({
    required this.items,
    required Map<String, int> agents,
    required this.damaged,
    required this.newer,
  }) : agents = Map.unmodifiable(agents);

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

  PageTally _with({
    int? items,
    Map<String, int>? agents,
    int damaged = 0,
    int newer = 0,
  }) => PageTally(
    items: items ?? this.items,
    agents: agents ?? this.agents,
    damaged: this.damaged + damaged,
    newer: this.newer + newer,
  );

  PageTally plusDamaged(int count) => _with(damaged: count);

  PageTally plusNewer(int count) => _with(newer: count);

  PageTally plusGroup(LineupGroupRow row, int sign) => switch (row) {
    UnreadableLineupGroup() => _with(damaged: sign),
    ReadableLineupGroupRow() => this,
  };

  PageTally plus(ElementRow row, int sign) {
    final counted = switch (row) {
      UnreadableElement(reason: Damaged()) => _with(damaged: sign),
      UnreadableElement(reason: FromNewerBuild()) => _with(newer: sign),
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
    final counts = {...agents};
    if (agent != null) {
      final count = (counts[agent] ?? 0) + sign;
      if (count == 0) {
        counts.remove(agent);
      } else {
        counts[agent] = count;
      }
    }
    return counted._with(items: items + sign, agents: counts);
  }

  Map<String, Object?> toJson() => {
    'items': items,
    'agents': {for (final key in agents.keys.sorted()) key: agents[key]},
    'damaged': damaged,
    'newer': newer,
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
        return () => PageTally(
          items: items,
          agents: {
            for (final MapEntry(:key, :value) in agents.entries)
              key: (value as num).toInt(),
          },
          damaged: damaged,
          newer: newer,
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
    required List<String> agents,
    required this.itemCount,
    required this.readability,
    required this.elsewhere,
    required Map<String, PageTally> tallies,
  }) : agents = List.unmodifiable(agents),
       tallies = Map.unmodifiable(tallies);

  factory StrategySummary.of({
    required ReadableStrategy strategy,
    required Iterable<PageRow> pages,
    required Iterable<PageSettingsRow> settings,
    required Map<String, PageTally> tallies,
    required PageTally elsewhere,
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
      readability: damaged == 0 && newer == 0
          ? const AllReadable()
          : SomeUnreadable(damaged: damaged, newer: newer),
      elsewhere: elsewhere,
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
  final Readability readability;
  final PageTally elsewhere;
  final Map<String, PageTally> tallies;

  StrategySummary after(
    ReadableStrategy strategy,
    Iterable<PageRow> pages,
    Iterable<PageSettingsRow> settings,
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
    for (final write in writes) {
      if (write case RowChanged(before: final LineupGroupRow before)) {
        tallies[before.pagePublicId] =
            (tallies[before.pagePublicId] ?? PageTally.empty).plusGroup(
              before,
              -1,
            );
      }
      if (write.after case final LineupGroupRow after) {
        tallies[after.pagePublicId] =
            (tallies[after.pagePublicId] ?? PageTally.empty).plusGroup(
              after,
              1,
            );
      }
    }
    return StrategySummary.of(
      strategy: strategy,
      pages: pages,
      settings: settings,
      tallies: tallies,
      elsewhere: elsewhere,
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
    readability: readability,
    elsewhere: elsewhere,
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
        final damaged = fields.whole('damagedRows');
        final newer = fields.whole('newerRows');
        final elsewhere = fields.decoded('elsewhere', PageTally.decode);
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
          agents: (agents! as List<Object?>).cast<String>(),
          itemCount: itemCount,
          readability: damaged == 0 && newer == 0
              ? const AllReadable()
              : SomeUnreadable(damaged: damaged, newer: newer),
          elsewhere: elsewhere!,
          tallies: tallies,
        );
      });

  @override
  bool operator ==(Object other) =>
      other is StrategySummary && sameJson(toJson(), other.toJson());

  @override
  int get hashCode => canonicalJson(toJson()).hashCode;
}
