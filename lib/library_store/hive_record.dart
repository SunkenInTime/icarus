import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/strategy/strategy_models.dart';

DateTime _asHiveStoresIt(DateTime time) =>
    DateTime.fromMillisecondsSinceEpoch(time.millisecondsSinceEpoch);

StrategyData strategyAsHiveHoldsIt(StrategyData strategy) => strategy.copyWith(
      createdAt: _asHiveStoresIt(strategy.createdAt),
      lastEdited: _asHiveStoresIt(strategy.lastEdited),
    );

Folder folderAsHiveHoldsIt(Folder folder) => Folder(
      name: folder.name,
      id: folder.id,
      dateCreated: _asHiveStoresIt(folder.dateCreated),
      iconId: folder.iconId,
      color: folder.color,
      parentID: folder.parentID,
      customColor: folder.customColor,
    );

final class HiveLibrary {
  HiveLibrary({
    required Iterable<StrategyData> strategies,
    required Iterable<Folder> folders,
  })  : strategies = List.unmodifiable(strategies.map(strategyAsHiveHoldsIt)),
        folders = List.unmodifiable(folders.map(folderAsHiveHoldsIt));

  final List<StrategyData> strategies;
  final List<Folder> folders;
}

String hiveRecordDigestOf(StrategyData strategy) => sha256
    .convert(utf8.encode(jsonEncode(_sorted(strategyFingerprint(strategy)))))
    .toString();

Object? _sorted(Object? json) => switch (json) {
      final Map<String, Object?> map => SplayTreeMap<String, Object?>.of({
          for (final MapEntry(:key, :value) in map.entries) key: _sorted(value),
        }),
      final List<Object?> list => [for (final item in list) _sorted(item)],
      _ => json,
    };
