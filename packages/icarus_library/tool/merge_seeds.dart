import 'dart:convert';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';

import 'merge_stories.dart';

const mergeSeedCount = 12;
const mergeSeedSteps = 60;

const _keptFields = [
  pictureIdField,
  'caption',
  'wallPath',
  'mapDoor',
  'isZone',
];

final mustGenerate = [
  'offline side edit carrying a stale position applied',
  'offline element move from a stale place refused',
  'offline lineup group move from a stale place refused',
  for (final field in _keptFields) 'older build write kept $field',
];

typedef RowsJson = Map<String, Object?> Function(StrategyRowSet rows);

List<Map<String, Object?>> mergeSeedScenarios(RowsJson rowsJson) {
  final reached = <String, int>{};
  final scenarios = [
    for (var seed = 0; seed < mergeSeedCount; seed++)
      _scenario(seed, rowsJson, reached),
  ];
  final missing = [
    for (final name in mustGenerate)
      if ((reached[name] ?? 0) == 0) name,
  ];
  if (missing.isNotEmpty) {
    throw StateError('The merge seeds never generated: ${missing.join(', ')}');
  }
  return scenarios;
}

Map<String, Object?> _scenario(
  int seed,
  RowsJson rowsJson,
  Map<String, int> reached,
) {
  final rng = Random(seed);
  T pick<T>(List<T> list) => list[rng.nextInt(list.length)];
  var rows = storyRows;
  final elementHistory = <String, List<LiveElement>>{
    for (final row in rows.elements.whereType<LiveElement>())
      row.publicId: [row],
  };
  final groupHistory = <String, List<LiveLineupGroup>>{
    for (final row in rows.lineupGroups.whereType<LiveLineupGroup>())
      row.publicId: [row],
  };
  List<LiveElement> liveElements() =>
      rows.elements.whereType<LiveElement>().toList();
  LiveLineupGroup group() =>
      rows.lineupGroups.whereType<LiveLineupGroup>().first;
  T older<T>(List<T> history) => history.length < 2
      ? history.first
      : history[rng.nextInt(history.length - 1)];

  Object? valueFor(String field) => switch (field) {
    'position' => {'x': rng.nextInt(20), 'y': rng.nextInt(20)},
    'isAlly' => rng.nextBool(),
    'color' => rng.nextInt(4),
    _ => 'note ${rng.nextInt(4)}',
  };

  List<String> fieldsOf(LiveElement row, {required bool sideOnly}) => [
    if (!sideOnly && row.payload.kind != ElementKind.drawing) 'position',
    'isAlly',
    'color',
    if (laterField(row.payload.kind, 'caption') != null) 'caption',
  ];

  ElementPayload changed(LiveElement row, String field) => ElementPayload(
    kind: row.payload.kind,
    payloadVersion: row.payload.payloadVersion,
    data: {...row.payload.data, field: valueFor(field)},
  );

  final ops = <StrategyOp>[];
  final predicted = <Map<String, Object?>>[];
  for (var step = 0; step < mergeSeedSteps; step++) {
    final opId = 'm$seed-op$step';
    final String? goal;
    final StrategyOp op;
    switch (rng.nextInt(6)) {
      case 0 || 1:
        final row = pick(liveElements());
        op = elementEditOp(
          opId: opId,
          base: row,
          drawn: DrawnAt(row.revision),
          payload: changed(row, pick(fieldsOf(row, sideOnly: false))),
          sortIndex: rng.nextInt(5) == 0 ? rng.nextInt(4) : row.sortIndex,
          connection: Connection.live,
        );
        goal = null;
      case 2:
        final current = pick(liveElements());
        final base = older(elementHistory[current.publicId]!);
        op = elementEditOp(
          opId: opId,
          base: base,
          drawn: DrawnAt(base.revision),
          payload: changed(base, pick(fieldsOf(base, sideOnly: true))),
          sortIndex: base.sortIndex,
          connection: Connection.offline,
        );
        goal =
            jsonEncode(base.payload.data['position']) ==
                jsonEncode(current.payload.data['position'])
            ? null
            : 'offline side edit carrying a stale position applied';
      case 3:
        final current = pick(liveElements());
        final base = older(elementHistory[current.publicId]!);
        op = elementEditOp(
          opId: opId,
          base: base,
          drawn: DrawnAt(base.revision),
          payload: base.payload,
          sortIndex: base.sortIndex + 1 + rng.nextInt(2),
          connection: Connection.offline,
        );
        goal = 'offline element move from a stale place refused';
      case 4:
        final current = group();
        final offline = rng.nextBool();
        final base = offline ? older(groupHistory[current.publicId]!) : current;
        op = lineupEditOp(
          opId: opId,
          base: base,
          drawn: DrawnAt(base.revision),
          payload: base.payload,
          sortIndex: base.sortIndex + 1 + rng.nextInt(2),
          connection: offline ? Connection.offline : Connection.live,
        );
        goal = offline
            ? 'offline lineup group move from a stale place refused'
            : null;
      default:
        final row = pick(liveElements());
        final stored = [
          for (final field in _keptFields)
            if (row.payload.data.containsKey(field)) field,
        ];
        op = ElementPatchOp(
          opId: opId,
          elementPublicId: row.publicId,
          expectedElementRevision: row.revision,
          payload: ElementPayload(
            kind: row.payload.kind,
            payloadVersion: row.payload.payloadVersion,
            data: {
              for (final MapEntry(:key, :value) in row.payload.data.entries)
                if (!_keptFields.contains(key)) key: value,
              'position': valueFor('position'),
            },
          ),
        );
        goal = stored.isEmpty ? null : 'older build write kept ${pick(stored)}';
    }
    final result = applyOp(rows, op);
    final counts = switch ((goal, result)) {
      (final String goal?, OpApplied(:final rows))
          when !goal.endsWith('refused') && _goalHolds(goal, op, rows) =>
        goal,
      (
        final String goal?,
        OpRefused(refusal: Rejected(reason: RejectionReason.fieldConflict)),
      )
          when goal.endsWith('refused') =>
        goal,
      _ => null,
    };
    if (counts != null) reached[counts] = (reached[counts] ?? 0) + 1;
    if (result is OpApplied) {
      rows = rows.withRows(result.rows);
      for (final row in result.rows) {
        switch (row) {
          case final LiveElement row:
            elementHistory[row.publicId]!.add(row);
          case final LiveLineupGroup row:
            groupHistory[row.publicId]!.add(row);
          case _:
            break;
        }
      }
    }
    ops.add(op);
    predicted.add({...outcomeJson(result), 'rows': rowsJson(rows)});
  }
  return {
    'name': 'merge seed $seed',
    'initial': rowsJson(storyRows),
    'ops': [for (final op in ops) op.toJson()],
    'predicted': predicted,
  };
}

bool _goalHolds(String goal, StrategyOp op, Iterable<Row> written) {
  const prefix = 'older build write kept ';
  if (!goal.startsWith(prefix) || op is! ElementPatchOp) return true;
  final field = goal.substring(prefix.length);
  return written.any(
    (row) =>
        row is LiveElement &&
        row.publicId == op.elementPublicId &&
        row.payload.data.containsKey(field),
  );
}
