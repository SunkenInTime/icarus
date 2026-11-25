import 'dart:convert';

import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

const lineupListKeys = ['lineUpOrigins', 'lineUpLandings', 'lineUpLinks'];

Map<String, Object?> pageFingerprint(StrategyPage page, String strategyId) => {
      'id': page.id,
      'sortIndex': page.sortIndex,
      'name': page.name,
      if (page.isAutoNamed case final isAutoNamed?) 'isAutoNamed': isAutoNamed,
      'drawingData': jsonDecode(DrawingProvider.objectToJson(page.drawingData)),
      'agentData': jsonDecode(AgentProvider.objectToJson(page.agentData)),
      'abilityData': jsonDecode(AbilityProvider.objectToJson(page.abilityData)),
      'textData': jsonDecode(TextProvider.objectToJson(page.textData)),
      'imageData': jsonDecode(
        PlacedImageProvider.objectToJson(page.imageData, strategyId),
      ),
      'utilityData': jsonDecode(UtilityProvider.objectToJson(page.utilityData)),
      'isAttack': page.isAttack,
      'settings':
          jsonDecode(StrategySettingsProvider.objectToJson(page.settings)),
      ...jsonDecode(jsonEncode(page.lineUpGraph.toJson()))
          as Map<String, Object?>,
    };

List<String> pagePictureFileNames(StrategyPage page) => [
      for (final image in page.imageData)
        '${image.pictureId}${image.fileExtension ?? ''}',
      ...lineupPictureFileNames(page),
    ];

List<String> lineupPictureFileNames(StrategyPage page) => [
      for (final link in page.lineUpLinks)
        for (final image in link.images) '${image.id}${image.fileExtension}',
    ];

List<String> pictureFileNames(StrategyData strategy) => [
      for (final page in strategy.pages) ...pagePictureFileNames(page),
    ]..sort();

Map<String, Object?> strategyFieldsFingerprint(StrategyData strategy) => {
      'id': strategy.id,
      'name': strategy.name,
      'versionNumber': strategy.versionNumber,
      'mapData': Maps.mapNames[strategy.mapData],
      'folderID': strategy.folderID,
      'themeProfileId': strategy.themeProfileId,
      'themeOverridePalette': switch (strategy.themeOverridePalette) {
        final palette? => [
            palette.baseColorValue,
            palette.detailColorValue,
            palette.highlightColorValue,
          ],
        null => null,
      },
      'createdAt': strategy.createdAt.toUtc().microsecondsSinceEpoch,
      'lastEdited': strategy.lastEdited.toUtc().microsecondsSinceEpoch,
    };

Map<String, Object?> strategyFingerprint(StrategyData strategy) => {
      ...strategyFieldsFingerprint(strategy),
      'pages': [
        for (final page in strategy.pages) pageFingerprint(page, strategy.id),
      ],
      'pictureFiles': pictureFileNames(strategy),
    };

enum DifferenceKind { value, pageOrder, lineupOrder, boundingBoxFilled }

final _drawingBox = RegExp(r'^pages\[\d+\]\.drawingData\[\d+\]\.boundingBox$');

final class StrategyDifference {
  const StrategyDifference(this.kind, this.path);

  final DifferenceKind kind;
  final String path;

  @override
  String toString() => '${kind.name} $path';
}

List<StrategyDifference> strategyDifferences(
  StrategyData expected,
  StrategyData actual,
) {
  final left = strategyFingerprint(expected);
  final right = strategyFingerprint(actual);
  final differences = <StrategyDifference>[];

  final leftPages = _pagesInOrder(left);
  final rightPages = _pagesInOrder(right);
  if (!_same(_ids(left['pages']), _ids(right['pages'])) &&
      _same(_ids(leftPages), _ids(rightPages))) {
    differences
        .add(const StrategyDifference(DifferenceKind.pageOrder, 'pages'));
  }
  for (final (index, page) in leftPages.indexed) {
    if (index >= rightPages.length) break;
    final other = rightPages[index];
    for (final key in lineupListKeys) {
      if (!_same(page[key], other[key]) &&
          _same(_byId(page[key]), _byId(other[key]))) {
        differences.add(
          StrategyDifference(DifferenceKind.lineupOrder, 'pages[$index].$key'),
        );
      }
    }
  }

  final normalizedLeft = {
    ...left,
    'pages': leftPages.map(_lineupsById).toList()
  };
  final normalizedRight = {
    ...right,
    'pages': rightPages.map(_lineupsById).toList()
  };
  _collect(
    _plain(normalizedLeft),
    _plain(normalizedRight),
    '',
    differences,
  );
  return differences;
}

List<Map<String, Object?>> _pagesInOrder(Map<String, Object?> fingerprint) => [
      ...(fingerprint['pages']! as List).cast<Map<String, Object?>>()
    ]..sort((a, b) {
        final bySort = (a['sortIndex']! as int).compareTo(
          b['sortIndex']! as int,
        );
        return bySort != 0
            ? bySort
            : (a['id']! as String).compareTo(b['id']! as String);
      });

List<Object?> _ids(Object? list) => [
      for (final item in list! as List) (item as Map<String, Object?>)['id'],
    ];

List<Map<String, Object?>> _byId(Object? list) => <Map<String, Object?>>[
      ...(list! as List).cast<Map<String, Object?>>()
    ]..sort((a, b) => (a['id']! as String).compareTo(b['id']! as String));

Map<String, Object?> _lineupsById(Map<String, Object?> page) => {
      ...page,
      for (final key in lineupListKeys) key: _byId(page[key]),
    };

Object? _plain(Object? json) => jsonDecode(jsonEncode(json));

bool _same(Object? left, Object? right) => switch ((left, right)) {
      (final Map<String, Object?> l, final Map<String, Object?> r) =>
        l.length == r.length &&
            l.entries.every(
              (entry) =>
                  r.containsKey(entry.key) && _same(entry.value, r[entry.key]),
            ),
      (final List<Object?> l, final List<Object?> r) => l.length == r.length &&
          [for (var i = 0; i < l.length; i++) i]
              .every((i) => _same(l[i], r[i])),
      _ => left == right,
    };

void _collect(
  Object? left,
  Object? right,
  String path,
  List<StrategyDifference> differences,
) {
  switch ((left, right)) {
    case (final Map<String, Object?> l, final Map<String, Object?> r):
      for (final key in {...l.keys, ...r.keys}) {
        final at = path.isEmpty ? key : '$path.$key';
        if (l.containsKey(key) != r.containsKey(key)) {
          differences.add(StrategyDifference(DifferenceKind.value, at));
        } else {
          _collect(l[key], r[key], at, differences);
        }
      }
    case (final List<Object?> l, final List<Object?> r):
      for (var i = 0; i < l.length && i < r.length; i++) {
        _collect(l[i], r[i], '$path[$i]', differences);
      }
      if (l.length != r.length) {
        differences
            .add(StrategyDifference(DifferenceKind.value, '$path.length'));
      }
    case (null, Map()) when _drawingBox.hasMatch(path):
      differences.add(
        StrategyDifference(DifferenceKind.boundingBoxFilled, path),
      );
    case _ when left != right:
      differences.add(StrategyDifference(DifferenceKind.value, path));
    case _:
  }
}
