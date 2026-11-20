import 'dart:convert';

import 'derived_id.dart';
import 'payloads.dart';
import 'rows.dart';
import 'strategy_rows.dart';

const _copyMark = '~cp1~';

const _maxKeptRootLength = 80;

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

String pageCopyRoot(String id) {
  final at = id.lastIndexOf(_copyMark);
  if (at <= 0) return id;
  return _uuid.hasMatch(id.substring(at + _copyMark.length))
      ? id.substring(0, at)
      : id;
}

String pageCopyId(String id, String fresh) {
  final root = pageCopyRoot(id);
  return Uri.encodeComponent(root).length > _maxKeptRootLength
      ? fresh
      : '$root$_copyMark$fresh';
}

final class PageCopy {
  PageCopy(this._opId, this._rows);

  final String _opId;
  final StrategyRows _rows;
  final _lineupIds = <String, String>{};
  final _made = <String>{};

  String _freeId(String kind, String sourceId, bool Function(String id) taken) {
    for (var attempt = 0; ; attempt++) {
      final id = pageCopyId(
        sourceId,
        derivedId(jsonEncode([_opId, 'copy', kind, sourceId, attempt])),
      );
      if (!taken(id) && _made.add('$kind/$id')) return id;
    }
  }

  String _elementId(String sourceId) =>
      _freeId('element', sourceId, (id) => _rows.element(id) != null);

  List<Row> content(
    Iterable<ElementRow> elements,
    Iterable<LineupGroupRow> lineupGroups,
    String pagePublicId,
  ) => [
    for (final element in elements)
      if (_isLive(element)) _element(element, pagePublicId),
    for (final group in lineupGroups)
      if (group is LiveLineupGroup) _lineupGroup(group, pagePublicId),
  ];

  bool _isLive(ElementRow element) => switch (element) {
    LiveElement() => true,
    DeletedElement() => false,
    UnreadableElement(:final json) => json['deleted'] == false,
  };

  ElementRow _element(ElementRow source, String pagePublicId) {
    switch (source) {
      case DeletedElement():
        throw ArgumentError.value(
          source,
          'source',
          'a deleted row is not copied',
        );
      case LiveElement(:final payload, :final sortIndex):
        final publicId = _elementId(source.publicId);
        return LiveElement(
          publicId: publicId,
          pagePublicId: pagePublicId,
          payload: ElementPayload(
            kind: payload.kind,
            payloadVersion: payload.payloadVersion,
            data: _copiedData(payload.kind.name, payload.data, publicId),
          ),
          sortIndex: sortIndex,
          revision: 1,
        );
      case UnreadableElement(:final json):
        final publicId = _elementId(source.publicId);
        return UnreadableElement(
          publicId: publicId,
          pagePublicId: pagePublicId,
          json: {
            ...json,
            'publicId': publicId,
            'pagePublicId': pagePublicId,
            'payload': switch (json['payload']) {
              {'data': final Map<String, Object?> data} &&
                  final Map<String, Object?> payload =>
                {
                  ...payload,
                  'data': _copiedData(payload['kind'], data, publicId),
                },
              final other => other,
            },
            'revision': 1,
          },
        );
    }
  }

  Map<String, Object?> _copiedData(
    Object? kind,
    Map<String, Object?> data,
    String publicId,
  ) {
    final pictureId = kind == ElementKind.image.name
        ? _pictureIdOf(data)
        : null;
    return {...data, 'id': publicId, 'assetId': ?pictureId};
  }

  String? _pictureIdOf(Map<String, Object?> data) => switch (data) {
    {'assetId': final String assetId} when assetId.isNotEmpty => assetId,
    {'id': final String id} => id,
    _ => null,
  };

  String _lineupId(Object? id) {
    final key = id is String ? id : '';
    return _lineupIds.putIfAbsent(
      key,
      () => _freeId('lineup', key, (id) => _rows.lineupGroup(id) != null),
    );
  }

  LiveLineupGroup _lineupGroup(LiveLineupGroup source, String pagePublicId) {
    final data = source.payload.data;
    final id = _lineupId(data['id']);
    Object? spot(Object? spot, String markerKey) {
      if (spot is! Map<String, Object?>) return spot;
      final spotId = _lineupId(spot['id']);
      final marker = spot[markerKey];
      return {
        ...spot,
        'id': spotId,
        if (marker is Map<String, Object?>)
          markerKey: {...marker, 'lineUpID': spotId},
      };
    }

    Object? link(Object? link) => link is Map<String, Object?>
        ? {
            ...link,
            'id': _lineupId(link['id']),
            'originId': _lineupId(link['originId']),
            'landingId': _lineupId(link['landingId']),
          }
        : link;

    List<Object?> entries(Object? value) =>
        value is List<Object?> ? value : const [];

    return LiveLineupGroup(
      strategyPublicId: source.strategyPublicId,
      publicId: id,
      pagePublicId: pagePublicId,
      payload: LineupGroupPayload(
        payloadVersion: source.payload.payloadVersion,
        data: {
          ...data,
          'id': id,
          'origins': [
            for (final origin in entries(data['origins']))
              spot(origin, 'agent'),
          ],
          'landings': [
            for (final landing in entries(data['landings']))
              spot(landing, 'ability'),
          ],
          'links': [for (final item in entries(data['links'])) link(item)],
        },
      ),
      sortIndex: source.sortIndex,
      revision: 1,
    );
  }
}
