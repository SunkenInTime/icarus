// The save-path gauntlet: a user edits cloud strategies in the app while the
// network fails under it, and the app must keep its promise. Every edit goes
// through the app's own op queue, Hive outbox and repository. At every check
// the sync chip must tell the truth: either it says synced, the outbox is
// empty and the server holds everything the user drew, or it says something
// else and names, in the queue state it reads, every change the server does
// not hold yet, each one kept in the outbox on disk.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_sync_status_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:uuid/uuid.dart';

import 'app.dart';
import 'editor.dart';
import 'faults.dart';
import 'server.dart';

const cloudProtocolVersion = 6;
const elementCount = 16;
const lineupCount = 4;
const roundCount = 12;
const editsPerRound = 18;

/// Elements a teammate edits too. The user never deletes them, so the
/// teammate's field must survive every edit the user makes.
const sharedElements = 4;

/// The element the teammate deletes while the user is still editing it.
const contestedElement = elementCount - 1;

/// Rounds that carry a fault, and where in the round it goes.
const _delayRound = 1;
const _twiceRound = 2;
const _loseAnswerRound = 3;
const _loseRequestRound = 4;
const _teammateMergeRound = 5;
const _offlineRound = 6;
const _reconnectRound = 7;
const _authOrRestartRound = 8;
const _teammateDeleteRound = 9;

final class GauntletFailure implements Exception {
  const GauntletFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

String _prefix(int seed) => 'seed-$seed-';
String strategyIdFor(int seed) => '${_prefix(seed)}strategy';
String _folderId(int seed) => '${_prefix(seed)}folder';
String _pageId(int seed) => '${_prefix(seed)}page-0';
String _elementId(int seed, int index) =>
    '${_prefix(seed)}element-${index.toString().padLeft(2, '0')}';
String _lineupId(int seed, int index) =>
    '${_prefix(seed)}lineup-${index.toString().padLeft(2, '0')}';

final class SavePathGauntlet {
  SavePathGauntlet({
    required this.deploymentUrl,
    required this.backendPort,
    required this.accountId,
    required this.accessToken,
    required this.refreshedAccessToken,
    required this.stateDirectory,
    required this.seedCount,
    required this.allowCheckpoint,
  });

  final String deploymentUrl;
  final int backendPort;
  final String accountId;
  final String accessToken;
  final String refreshedAccessToken;

  /// Survives the process restart: the app's Hive directory and the
  /// gauntlet's progress.
  final String stateDirectory;
  final int seedCount;
  final bool allowCheckpoint;

  File get _progressFile => File('$stateDirectory/progress.json');
  String get _hiveDirectory => '$stateDirectory/hive';

  late GauntletApp _app;
  late ServerLine _server;
  late _Progress _progress;
  Editor? _editor;

  Future<void> reset() async {
    final directory = Directory(stateDirectory);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<Map<String, Object?>> run() async {
    final wallClock = Stopwatch()..start();
    await Directory(_hiveDirectory).create(recursive: true);
    _progress = await _loadProgress();
    final token = _progress.tokenRefreshed ? refreshedAccessToken : accessToken;
    _server = ServerLine(deploymentUrl: deploymentUrl, accessToken: token);
    _app = await GauntletApp.start(
      hiveDirectory: _hiveDirectory,
      backendPort: backendPort,
      accountId: accountId,
      accessToken: token,
    );
    try {
      while (_progress.seed < seedCount) {
        final checkpoint = await _runSeed(_progress.seed);
        if (checkpoint) {
          _progress.processRestarts += 1;
          _progress.wallClockMs += wallClock.elapsedMilliseconds;
          // The process ends here as a crash would: Hive is not closed, and
          // the next process opens what its awaited writes left on disk.
          await _saveProgress();
          return {
            'status': 'checkpoint',
            'seed': _progress.seed,
            'round': _progress.round,
          };
        }
        _progress
          ..seed += 1
          ..round = 0
          ..seedStarted = false
          ..editor = null
          ..current = {};
        await _saveProgress();
      }
      await _app.close();
      return {
        'status': 'passed',
        'seedCount': seedCount,
        'processRestarts': _progress.processRestarts,
        'wallClockMs': _progress.wallClockMs + wallClock.elapsedMilliseconds,
        'seeds': _progress.reports,
      };
    } on GauntletFailure catch (failure) {
      return {
        'status': 'failed',
        'losingCondition': failure.code,
        'message': failure.message,
        'seed': _progress.seed,
        'round': _progress.round,
        'partialSeed': _progress.current,
        'seeds': _progress.reports,
      };
    } finally {
      _server.close();
    }
  }

  /// Runs [seed] from the round the progress is at. True when the process
  /// should end here, at the restart checkpoint.
  Future<bool> _runSeed(int seed) async {
    final strategyId = strategyIdFor(seed);
    final pageId = _pageId(seed);
    if (!_progress.seedStarted) {
      await _app.repository.createFolder(
        publicId: _folderId(seed),
        name: 'Gauntlet seed $seed',
      );
      await _app.repository.createStrategyWithInitialPage(
        publicId: strategyId,
        name: 'Gauntlet seed $seed',
        mapData: 'ascent',
        folderPublicId: _folderId(seed),
        initialPagePublicId: pageId,
        initialPageName: 'Page 0',
        initialPageIsAttack: true,
      );
      _progress
        ..seedStarted = true
        ..current = _newSeedReport(seed);
    }
    _app.open(strategyId);
    final editor = Editor(_app, strategyId: strategyId, pageId: pageId);
    _editor = editor;
    if (_progress.editor case final saved?) editor.restore(saved);
    editor.hydrate(await _snapshot(seed));
    if (_progress.editor != null) {
      // The strategy opens drawn from the server, showing the teammate's
      // field that this device never drew before it closed.
      for (final MapEntry(key: id, value: fields) in _teammateFields.entries) {
        final data = editor.drawn[id]?.payload?['data'];
        if (data is Map) data.addAll(fields);
      }
    }
    final random = Random(seed * 1000 + _progress.round);
    try {
      while (_progress.round < roundCount) {
        final round = _progress.round;
        stdout.writeln('seed $seed round $round: chip ${_app.chip.name}, '
            '${_app.queueState.pending.length} change(s) waiting');
        if (await _runRound(seed, round, editor, random)) return true;
        _progress
          ..round += 1
          ..editor = editor.toJson();
        await _check(seed, 'end of round $round');
        _recordAnswers();
        await _saveProgress();
      }
      await _finishSeed(seed, editor);
      return false;
    } finally {
      editor.close();
      _editor = null;
    }
  }

  Map<String, Object?> get _faults =>
      _progress.current['faults'] as Map<String, Object?>;

  /// One round of edits with its fault. True at the restart checkpoint.
  Future<bool> _runRound(
    int seed,
    int round,
    Editor editor,
    Random random,
  ) async {
    final checkpointSeed = seedCount > 1 ? 1 : 0;
    switch (round) {
      case 0:
        for (var index = 0; index < elementCount; index += 1) {
          await _drawElement(editor, seed, index, variant: 0);
        }
        for (var index = 0; index < lineupCount; index += 1) {
          await _drawLineup(editor, seed, index, variant: 0);
        }
        await _deleteWhileClaiming(seed, editor);
        await _editWhileAddAnswered(seed, editor);
      case _delayRound:
        _app.transport.inject(BatchFault.delay);
        _faults['delayedDelivery'] = true;
      case _twiceRound:
        _app.transport.inject(BatchFault.deliverTwice);
        _faults['duplicatedDelivery'] = true;
      case _teammateMergeRound:
        await _teammateEditsShared(seed);
        _faults['revisionConflictMerged'] = true;
      case _offlineRound:
        await _losePageChangeAnswer(seed, editor);
        await _goOffline();
        _faults['offlineQueuedEdits'] = true;
      case _authOrRestartRound when seed == 0:
        _rejectTokenUnderNextBatch();
      case _authOrRestartRound
          when seed == checkpointSeed &&
              allowCheckpoint &&
              !_progress.didCheckpoint:
        return _crashWithWorkInFlight(seed, editor, random);
      case _teammateDeleteRound:
        await _contest(seed, editor);
    }

    await _edit(seed, editor, random, round);
    final losesBatch = round == _loseAnswerRound || round == _loseRequestRound;
    if (losesBatch) {
      // The batch holding the round's last edits fails, and the user edits
      // the same items again before it is sent again.
      _app.transport.inject(round == _loseAnswerRound
          ? BatchFault.loseAnswer
          : BatchFault.loseRequest);
      _faults[round == _loseAnswerRound ? 'lostAnswer' : 'lostRequest'] = true;
      await _editWhileResendWaits(seed, editor, round);
    }
    if (round == _reconnectRound) {
      final connected = await _reconnect();
      _progress.current['reconnectMs'] = connected.inMilliseconds;
      _faults['reconnect'] = true;
    }
    await _pageWork(seed, editor, round);

    if (round == _offlineRound) {
      // Everything made offline is waiting, and the chip must say so.
      await _settle(seed, allowOffline: true);
      final shown = await _check(seed, 'offline with edits waiting');
      if (shown == CloudSyncStatus.synced) {
        throw const GauntletFailure(
          'offline_shown_synced',
          'The chip said synced while the app was offline with edits waiting',
        );
      }
      await _goOnline();
      // Nothing more is edited: the queue must send what waited by itself.
      final resumed = Stopwatch()..start();
      await _settle(seed, timeout: const Duration(seconds: 40));
      _progress.current['syncedAfterReconnectMs'] = resumed.elapsedMilliseconds;
    }
    if (round == _authOrRestartRound && seed == 0) {
      await _refreshToken(seed, editor);
    }
    return false;
  }

  Future<void> _edit(int seed, Editor editor, Random random, int round) async {
    for (var edit = 0; edit < editsPerRound; edit += 1) {
      if (random.nextInt(4) == 0) {
        final index = random.nextInt(lineupCount);
        await _drawLineup(editor, seed, index, variant: round * 100 + edit);
      } else {
        final index = random.nextInt(elementCount);
        final id = _elementId(seed, index);
        final drawnNow = editor.drawn[id];
        final deletable = index >= sharedElements && index != contestedElement;
        if (drawnNow?.payload == null) {
          // Live sync remakes a waiting op from its live read once the
          // delete before it lands; the stand-in makes each op once, so the
          // user brings an item back only after its delete has landed. A
          // delete made offline waits for the network, so offline the user
          // leaves the item alone.
          if (_app.proxy.isOffline && _waitsInOutbox(id)) continue;
          await _waitFor(
            'the delete of $id to land',
            () => !_waitsInOutbox(id),
          );
          await _drawElement(editor, seed, index, variant: round * 100 + edit);
          _faults['deleteRecreate'] = true;
        } else if (deletable && random.nextInt(8) == 0) {
          await editor.draw(id, payload: null, sortIndex: drawnNow!.sortIndex);
        } else {
          await _drawElement(
            editor,
            seed,
            index,
            variant: round * 100 + edit,
            sortIndex: random.nextInt(5) == 0
                ? 500 + round * 50 + edit
                : drawnNow!.sortIndex,
          );
        }
      }
      _progress.current['userEdits'] =
          (_progress.current['userEdits'] as int) + 1;
      // Bursts of edits with a pause now and then, as a person makes them.
      // The queue sends 180 ms after the last edit, so edits keep landing
      // on it while earlier ones are being sent.
      await Future<void>.delayed(Duration(
        milliseconds: random.nextInt(5) == 0
            ? 200 + random.nextInt(250)
            : random.nextInt(25),
      ));
    }
    await editor.setPageSettings({
      'agentSize': 30 + round,
      'abilitySize': 20 + round,
      'useNeutralTeamColors': round.isEven,
    });
  }

  /// Waits for the batch holding the round's last edits to fail, then edits
  /// again what it held, before the queue sends it again: the page's
  /// settings and its elements. When the lost answer was an accept, the
  /// server holds the first edits, and the second ones must still land,
  /// unasked.
  Future<void> _editWhileResendWaits(int seed, Editor editor, int round) async {
    List<StrategyOp> failed() => [
          for (final intent in _app.queueState.queuedByEntityKey.values)
            if (intent.pending.attempts > 0) intent.pending.op,
        ];
    await _waitFor('the batch to fail', () => failed().isNotEmpty);
    // Whether an edit was queued behind the failed op of its own item,
    // which is what this round is for.
    var waitedBehind = false;
    bool behindFailed(StrategyOp op) {
      final key = EntitySyncKey.forStrategyOp(op)!;
      return _app.queueState.queuedByEntityKey[key]?.pending.op.opId ==
              op.opId &&
          _app.queueState.successorByEntityKey.containsKey(key);
    }

    for (final op in failed()) {
      if (op is PageContentPatchOp) {
        await editor.setPageSettings({
          ...?editor.pageSettings,
          'agentSize': 60 + round,
        });
        waitedBehind |= behindFailed(op);
        continue;
      }
      final id = op.entityPublicId;
      if (id == null || Editor.isLineup(id)) continue;
      final index = int.tryParse(id.split('element-').last);
      if (index == null || editor.drawn[id]?.payload == null) continue;
      await _drawElement(editor, seed, index, variant: round * 100 + 99);
      waitedBehind |= behindFailed(op);
    }
    if (waitedBehind) _faults['editedWhileResendWaits'] = true;
  }

  /// Adds an item and deletes it just after the queue starts sending the
  /// add, at a slightly later moment each time, so some delete lands while
  /// the queue is claiming the batch: it must wait behind the add, not be
  /// folded into it.
  Future<void> _deleteWhileClaiming(int seed, Editor editor) async {
    for (var step = 0; step < 16; step += 1) {
      final id = '${_prefix(seed)}element-claimed-$step';
      final payload = cloudElementPayload(kind: 'utility', data: {
        'id': id,
        'isDeleted': false,
        'position': {'dx': 300.0 + step, 'dy': 300.0},
        'type': 'customCircle',
        'rotation': 0.0,
        'length': 0.0,
        'angle': 0.0,
        'attachedAgentId': null,
        'customDiameter': 8.0,
        'customWidth': null,
        'customLength': null,
        'customColorValue': 4282090230,
        'customOpacityPercent': 30,
      });
      await editor.draw(id, payload: payload, sortIndex: 2000 + step);
      // The queue sends 180 ms after the last edit.
      await Future<void>.delayed(Duration(milliseconds: 176 + step * 3));
      await editor.draw(id, payload: null, sortIndex: 2000 + step);
    }
    _faults['deleteDuringSendSweep'] = true;
  }

  /// Adds an item and moves it as the answer to the add reaches the app,
  /// a moment later each time, so some move is made while the queue stores
  /// that answer, before the editor hears of it: made as an add, it must
  /// land as a move of the added item.
  Future<void> _editWhileAddAnswered(int seed, Editor editor) async {
    // Moves made before the editor heard the add landed: made as adds.
    var raced = 0;
    for (var step = 0; step < 6; step += 1) {
      final id = '${_prefix(seed)}element-answered-$step';
      Map<String, dynamic> at(double dx) =>
          cloudElementPayload(kind: 'utility', data: {
            'id': id,
            'isDeleted': false,
            'position': {'dx': dx, 'dy': 400.0 + step},
            'type': 'customCircle',
            'rotation': 0.0,
            'length': 0.0,
            'angle': 0.0,
            'attachedAgentId': null,
            'customDiameter': 8.0,
            'customWidth': null,
            'customLength': null,
            'customColorValue': 4282090230,
            'customOpacityPercent': 30,
          });
      final answered = _app.transport.batchAnswered.first;
      await editor.draw(id, payload: at(300), sortIndex: 3000 + step);
      await answered.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw GauntletFailure(
          'timeout',
          'The add of $id was never answered',
        ),
      );
      await Future<void>.delayed(Duration(microseconds: step * 500));
      if (!_app.queueState.lastAckBatch
          .any((acked) => acked.op.entityPublicId == id)) {
        raced += 1;
      }
      await editor.draw(id, payload: at(340), sortIndex: 3000 + step);
      await _settle(seed);
    }
    _progress.current['movesMadeAsAdds'] = raced;
    if (raced > 0) _faults['editWhileAddAnswered'] = true;
  }

  bool _waitsInOutbox(String id) =>
      _app.queueState.pending.any((pending) => pending.op.entityPublicId == id);

  Future<void> _pageWork(int seed, Editor editor, int round) async {
    final first = '${_prefix(seed)}page-1';
    final second = '${_prefix(seed)}page-2';
    switch (round) {
      case 1:
        await editor.addPage(first, 'Retake', 1);
        await editor.renameStrategy('Gauntlet seed $seed, round 1');
      case 2:
        await editor.renamePage(first, 'Retake A');
      case 3:
        await editor.movePage(first, 0);
        await editor.renameStrategy('Gauntlet seed $seed, round 3');
      case 4:
        await editor.deletePage(first);
      case 5:
        await editor.addPage(second, 'Execute', 1);
      case _offlineRound:
        await editor.renamePage(second, 'Execute B');
        await editor.renameStrategy('Gauntlet seed $seed, offline');
      case 10:
        await editor.movePage(second, 0);
        await editor.renameStrategy('Gauntlet seed $seed, final');
    }
  }

  Future<void> _drawElement(
    Editor editor,
    int seed,
    int index, {
    required int variant,
    int? sortIndex,
  }) {
    final id = _elementId(seed, index);
    return editor.draw(
      id,
      payload: cloudElementPayload(kind: 'utility', data: {
        'id': id,
        'isDeleted': false,
        'position': {
          'dx': 100.0 + index * 10 + variant % 7,
          'dy': 150.0 + variant % 11,
        },
        'type': 'customCircle',
        'rotation': 0.0,
        'length': 0.0,
        'angle': 0.0,
        'attachedAgentId': null,
        'customDiameter': 10.0 + variant % 5,
        'customWidth': null,
        'customLength': null,
        'customColorValue': 4282090230,
        // The user never changes it; it stays as the canvas shows it.
        'customOpacityPercent': (editor.drawn[id]?.payload?['data']
                as Map?)?['customOpacityPercent'] ??
            30,
      }),
      sortIndex: sortIndex ?? editor.drawn[id]?.sortIndex ?? 100 + index,
    );
  }

  Future<void> _drawLineup(
    Editor editor,
    int seed,
    int index, {
    required int variant,
  }) {
    final id = _lineupId(seed, index);
    return editor.draw(
      id,
      payload: cloudLineupsPayload({
        'id': id,
        'origins': [
          {
            'id': '$id-origin',
            'agent': {
              'id': '$id-agent',
              'isDeleted': false,
              'position': {'dx': 10.0 + index, 'dy': 20.0 + variant % 13},
              'type': 'sova',
              'isAlly': true,
              'state': 'none',
              'kind': 'plain',
              'lineUpID': '$id-origin',
            },
          },
        ],
        'landings': [
          {
            'id': '$id-landing',
            'ability': {
              'id': '$id-ability',
              'isDeleted': false,
              'position': {'dx': 40.0 + index, 'dy': 50.0 + variant % 3},
              'data': {'type': 'sova', 'index': 1},
              'isAlly': true,
              'rotation': 0.0,
              'length': 0.0,
              'lineUpID': '$id-landing',
            },
          },
        ],
        'links': [
          {
            'id': '$id-link',
            'originId': '$id-origin',
            'landingId': '$id-landing',
            'name': 'Lineup $index',
            'youtubeLink': '',
            'notes': '',
            'images': <Object?>[],
          },
        ],
      }),
      sortIndex: 1000 + index,
    );
  }

  // --- The teammate: another device of the same account, writing to the
  // server directly. ---

  /// Values the teammate wrote, by element id and field: the server must
  /// keep each one, since the user never changes that field.
  Map<String, Map<String, Object?>> get _teammateFields =>
      (_progress.current['teammateFields'] as Map).map(
        (key, value) => MapEntry(
          key as String,
          (value as Map).cast<String, Object?>(),
        ),
      );

  Future<void> _teammateEditsShared(int seed) async {
    final snapshot = await _snapshot(seed);
    final rows = {
      for (final row in (snapshot['elements'] as List).cast<Map>())
        row['publicId'] as String: row,
    };
    final fields = <String, Map<String, Object?>>{};
    final ops = <Map<String, Object?>>[];
    for (var index = 0; index < sharedElements; index += 1) {
      final id = _elementId(seed, index);
      final row = rows[id];
      if (row == null || row['deleted'] == true) continue;
      final payload = jsonDecode(jsonEncode(row['payload'])) as Map;
      final opacity = 60 + index;
      (payload['data'] as Map)['customOpacityPercent'] = opacity;
      fields[id] = {'customOpacityPercent': opacity};
      ops.add(ElementPatchOp(
        opId: const Uuid().v4(),
        elementPublicId: id,
        pagePublicId: _pageId(seed),
        payload: payload.cast<String, dynamic>(),
        sortIndex: (row['sortIndex'] as num).toInt(),
        expectedElementRevision: (row['revision'] as num).toInt(),
        merge: const FieldMerge(fields: ['customOpacityPercent']),
      ).toConvexJson());
    }
    final statuses = await _teammateBatch(seed, ops);
    if (statuses.any((status) => status != 'applied')) {
      throw GauntletFailure(
        'teammate_refused',
        "The server refused the teammate's edits: $statuses",
      );
    }
    _progress.current['teammateFields'] = fields;
  }

  /// The teammate deletes the contested element, and the user, who hasn't
  /// seen that yet, moves it. The server must refuse the move and the app
  /// must say so, until the user takes the teammate's delete.
  Future<void> _contest(int seed, Editor editor) async {
    final id = _elementId(seed, contestedElement);
    await _settle(seed);
    final snapshot = await _snapshot(seed);
    final row = (snapshot['elements'] as List)
        .cast<Map>()
        .singleWhere((row) => row['publicId'] == id);
    final statuses = await _teammateBatch(seed, [
      ElementDeleteOp(
        opId: const Uuid().v4(),
        elementPublicId: id,
        pagePublicId: _pageId(seed),
        expectedElementRevision: (row['revision'] as num).toInt(),
      ).toConvexJson(),
    ]);
    if (statuses.single != 'applied') {
      throw GauntletFailure(
        'teammate_refused',
        "The server refused the teammate's delete: $statuses",
      );
    }
    await _drawElement(editor, seed, contestedElement, variant: 9999);
    await _settle(seed);
    final shown = await _check(seed, 'a move of an element a teammate deleted');
    final key = EntitySyncKey.element(_pageId(seed), id);
    if (shown != CloudSyncStatus.attention ||
        !_app.queueState.attentionByEntityKey.containsKey(key)) {
      throw GauntletFailure(
        'refusal_not_shown',
        'The server refused a move of $id, deleted by a teammate, and the '
            'chip showed $shown',
      );
    }
    _faults['revisionConflictRefused'] = true;
    // The user takes the teammate's delete, as Keep theirs does, and the
    // canvas draws the server's version.
    await _app.queue.discardRejected({key});
    final after = await _snapshot(seed);
    editor.adopt((after['elements'] as List)
        .cast<Map>()
        .singleWhere((row) => row['publicId'] == id));
    _app.queue.completeRemoteAdoption({key});
  }

  Future<List<String>> _teammateBatch(
    int seed,
    List<Map<String, Object?>> ops,
  ) async {
    final result = await _server.mutation('ops:applyBatch', {
      'strategyPublicId': strategyIdFor(seed),
      'clientId': 'gauntlet-teammate',
      'clientProtocolVersion': cloudProtocolVersion,
      'ops': ops,
      'accountSubject': accountId,
      'checkTrashedPageDeletes': true,
      'acceptsPictureIds': true,
      'elementFieldLevel': 3,
    }) as Map;
    return [
      for (final item in (result['results'] as List).cast<Map>())
        item['status'] as String,
    ];
  }

  // --- Faults at the network and process. ---

  /// The user adds a page and the answer to it is lost, after the server
  /// applied it. The strategy changes the user then makes offline are made
  /// against the revision before the add, and must land once the add is
  /// sent again.
  Future<void> _losePageChangeAnswer(int seed, Editor editor) async {
    await _settle(seed);
    _app.transport.inject(BatchFault.loseAnswer);
    await editor.addPage('${_prefix(seed)}page-3', 'Lurk', 2);
    await _waitFor(
      'the page add to fail',
      () => _app.queueState.pending.any(
        (pending) => pending.op is PageAddOp && pending.attempts > 0,
      ),
    );
    _faults['lostPageChangeAnswer'] = true;
  }

  Future<void> _goOffline() async {
    // Cut whatever is being sent, a page change included: its answer is
    // lost, and the strategy changes made offline must still land once it
    // is sent again.
    _app.proxy.goOffline();
    await _waitFor(
      'the app to see it is offline',
      () => !_app.container.read(convexConnectionSnapshotProvider),
    );
  }

  Future<void> _goOnline() async {
    _app.proxy.goOnline();
    await _waitFor(
      'the app to reconnect',
      () => _app.container.read(convexConnectionSnapshotProvider),
      timeout: const Duration(seconds: 40),
    );
  }

  Future<Duration> _reconnect() async {
    final stopwatch = Stopwatch()..start();
    await _app.reconnect();
    return stopwatch.elapsed;
  }

  /// The next batch is held as the app sends it, the server starts refusing
  /// the app's token, and then the batch goes out under it. The user keeps
  /// editing meanwhile.
  void _rejectTokenUnderNextBatch() {
    _faults['authRefresh'] = true;
    final auth = _progress.current['auth'] as Map<String, Object?>;
    _app.transport.inject(BatchFault.holdUntilReleased);
    unawaited(() async {
      await _app.transport.batchSent.first;
      await _app.signIn(_rejectedToken);
      _app.transport.release();
      auth['batchSentUnderRejectedToken'] = true;
    }());
  }

  /// The session refreshes. What the user made under the refused token must
  /// land now, once.
  Future<void> _refreshToken(int seed, Editor editor) async {
    await _waitFor(
      'a batch to go out under the refused token',
      () => _app.transport.isClear,
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    final auth = _progress.current['auth'] as Map<String, Object?>;
    final stopwatch = Stopwatch()..start();
    _app.refreshTokenTo(refreshedAccessToken);
    _server.accessToken = refreshedAccessToken;
    _progress.tokenRefreshed = true;
    try {
      await _settle(seed, timeout: const Duration(seconds: 30));
    } on GauntletFailure {
      throw const GauntletFailure(
        'queued_batch_lost',
        'The work made under a refused token did not land after the session '
            'refreshed',
      );
    }
    auth['landedAfterRefreshMs'] = stopwatch.elapsedMilliseconds;
    auth['unauthenticatedReports'] = _app.auth.unauthenticatedReports;
    final shown = await _check(seed, 'after the session refreshed');
    if (shown != CloudSyncStatus.synced) {
      throw GauntletFailure(
        'queued_batch_lost',
        'After the session refreshed the chip showed $shown',
      );
    }
    auth['landedOnce'] = true;
  }

  /// A batch is sent and the server applies it, then the process dies
  /// before the answer arrives, with more edits queued behind it.
  Future<bool> _crashWithWorkInFlight(
    int seed,
    Editor editor,
    Random random,
  ) async {
    await _settle(seed);
    final answered = _app.transport.seen.length;
    _app.transport.inject(BatchFault.holdAnswerForever);
    for (var index = 0; index < 6; index += 1) {
      await _drawElement(editor, seed, index, variant: 7000 + index);
    }
    await _waitFor(
      'the server to apply the batch the process dies holding',
      () => _app.transport.seen.length > answered,
    );
    for (var index = 6; index < 10; index += 1) {
      await _drawElement(editor, seed, index, variant: 7000 + index);
    }
    await _check(seed, 'the moment before the process dies');
    final waiting = _app
        .outboxOnDisk()
        .where((record) => record.strategyPublicId == strategyIdFor(seed));
    if (waiting.isEmpty) {
      throw const GauntletFailure(
        'nothing_in_flight_at_restart',
        'The outbox held nothing when the process died with a batch in flight',
      );
    }
    _faults['processRestart'] = true;
    _progress.current['outboxRecordsAtRestart'] = waiting.length;
    _recordAnswers();
    _progress
      ..didCheckpoint = true
      ..round += 1
      ..editor = editor.toJson();
    return true;
  }

  // --- Checks. ---

  /// Waits for the app to stop sending: the chip shows something other than
  /// syncing and the queue has nothing it could send right now.
  Future<void> _settle(
    int seed, {
    bool allowOffline = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    DateTime? quietSince;
    while (true) {
      final chip = _app.chip;
      final queue = _app.queueState;
      final quiet = chip != CloudSyncStatus.syncing &&
          (allowOffline || chip != CloudSyncStatus.offline) &&
          !queue.isFlushing &&
          queue.inFlightByEntityKey.isEmpty &&
          (queue.queuedByEntityKey.isEmpty || chip == CloudSyncStatus.offline);
      if (quiet) {
        quietSince ??= DateTime.now();
        if (DateTime.now().difference(quietSince) >
            const Duration(milliseconds: 400)) {
          return;
        }
      } else {
        quietSince = null;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw GauntletFailure(
          'never_settled',
          'Seed $seed: after ${timeout.inSeconds} s the chip still shows '
              '$chip with ${queue.pending.length} change(s) waiting '
              '(${queue.lastError ?? 'no error'}): ${_held()}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// What the server answered for each item this process sent, for
  /// failure messages.
  final Map<String, List<String>> _history = {};

  /// The work the outbox holds back, why, and what the server answered for
  /// it before, for failure messages.
  String _held() {
    _recordAnswersQuietly();
    return [
      for (final record in _app.outboxOnDisk())
        if (record.status.name == 'attention' || record.status.name == 'paused')
          '${record.entityKey} ${record.pending.op.type.wireName} at '
              '${record.pending.op.expectedRevision} '
              '(${record.lastError}; server at '
              '${record.latestServerRevision}); sent before: '
              '${(_history[_subjectOf(record.pending.op)] ?? const []).join(' | ')}',
    ].join('; ');
  }

  void _recordAnswersQuietly() {
    try {
      _recordAnswers();
    } on GauntletFailure {
      // The failure being reported comes first.
    }
  }

  /// The chip's promise, checked against the outbox on disk and the server.
  Future<CloudSyncStatus> _check(int seed, String moment) async {
    // Read together, before the server: anything that lands while the
    // server is read only brings the server closer to the user's work.
    final chip = _app.chip;
    final saved = _app.saveState.canLeaveSafely;
    final queue = _app.queueState;
    final strategyId = strategyIdFor(seed);
    final onDisk = _app.outboxOnDisk();
    final named = {
      for (final pending in queue.pending) _subjectOf(pending.op),
    };
    final otherStrategies = queue.accountOutbox.strategies.keys
        .where((id) => id != strategyId)
        .toList();
    final snapshot = await _snapshot(seed);
    final missing = _notOnServer(seed, snapshot);

    void fail(String code, String message) => throw GauntletFailure(
          code,
          'Seed $seed, $moment: $message',
        );

    if (otherStrategies.isNotEmpty) {
      fail(
          'work_left_behind',
          'the outbox still holds work for '
              '$otherStrategies');
    }
    if (saved && onDisk.isNotEmpty) {
      fail(
        'saved_with_work_in_outbox',
        'the save state says everything is saved while the outbox on disk '
            'holds ${onDisk.length} record(s)',
      );
    }
    if (chip == CloudSyncStatus.synced) {
      if (onDisk.isNotEmpty) {
        fail(
          'synced_with_work_in_outbox',
          'the chip says synced while the outbox on disk holds '
              '${onDisk.length} record(s): '
              '${onDisk.map((record) => record.entityKey).join(', ')}',
        );
      }
      if (missing.isNotEmpty) {
        fail(
          'synced_but_not_on_server',
          'the chip says synced but the server does not hold '
              '${missing.join(', ')}',
        );
      }
    } else {
      final unnamed = missing.where((subject) => !named.contains(subject));
      if (unnamed.isNotEmpty) {
        fail(
          'unsaved_work_not_shown',
          'the chip shows $chip, and the server does not hold '
              '${unnamed.join(', ')}, which the app does not list as waiting',
        );
      }
      final diskSubjects = {
        for (final record in onDisk) ...[
          _subjectOf(record.pending.op),
          if (record.successorPending case final successor?)
            _subjectOf(successor.op),
        ],
      };
      // Only work the server lacks must be on disk. While the queue clears
      // an accepted batch it removes the records one write at a time and
      // updates its waiting list once at the end, so in between the list
      // can still name work that has landed and left the disk.
      final notKept = named.where(
        (subject) =>
            missing.contains(subject) && !diskSubjects.contains(subject),
      );
      if (notKept.isNotEmpty) {
        fail(
          'waiting_work_not_on_disk',
          'the app lists ${notKept.join(', ')} as waiting, and neither the '
              'server nor the outbox on disk holds it',
        );
      }
      // Waiting is not enough: the newest op the outbox holds for an item
      // must write what the user drew last, or an earlier edit stands in
      // for a lost later one.
      final newest = {
        for (final record in onDisk)
          _subjectOf(record.pending.op):
              (record.successorPending ?? record.pending).op,
      };
      final editor = _editor!;
      for (final id in missing) {
        final op = newest[id];
        if (op == null) continue;
        final drawn = editor.drawn[id];
        // Page changes wait as an ordered list, not as one newest op.
        final bool writesDrawn;
        if (op is PageContentPatchOp) {
          writesDrawn = _same(op.settings, editor.pageSettings);
        } else if (op is StrategyPatchOp) {
          writesDrawn = op.payload['name'] == editor.strategyName;
        } else if (drawn == null) {
          continue;
        } else {
          writesDrawn = drawn.payload == null
              ? op is ElementDeleteOp || op is LineupDeleteOp
              : _same(op.payload, drawn.payload) &&
                  op.sortIndex == drawn.sortIndex;
        }
        if (!writesDrawn) {
          fail(
            'latest_edit_not_kept',
            'the outbox holds ${op.type.wireName} for $id, which is not '
                'what the user drew last',
          );
        }
      }
    }
    final checks = _progress.current['checks'] as Map<String, Object?>;
    checks[chip.name] = ((checks[chip.name] as int?) ?? 0) + 1;
    return chip;
  }

  /// What an op changes, named the way [_notOnServer] names it.
  static String _subjectOf(StrategyOp op) => switch (op) {
        StrategyPatchOp() => 'strategy',
        PageContentPatchOp(:final pagePublicId) => 'settings:$pagePublicId',
        PageAddOp(:final pagePublicId) ||
        PagePatchOp(:final pagePublicId) ||
        PageDeleteOp(:final pagePublicId) ||
        PageReorderOp(:final pagePublicId) =>
          'page:$pagePublicId',
        _ => op.entityPublicId ?? op.opId,
      };

  /// Everything the user drew that the server does not hold.
  List<String> _notOnServer(int seed, Map<String, Object?> snapshot) {
    final editor = _editor!;
    final missing = <String>[];
    final header = (snapshot['header'] as Map).cast<String, Object?>();
    if (editor.strategyName != null && header['name'] != editor.strategyName) {
      missing.add('strategy');
    }
    final pages = {
      for (final page in (snapshot['pages'] as List).cast<Map>())
        page['publicId'] as String: page,
    };
    for (final MapEntry(key: id, value: name) in editor.pageNames.entries) {
      if (pages[id]?['name'] != name) missing.add('page:$id');
    }
    for (final MapEntry(key: id, value: sortIndex)
        in editor.pageOrder.entries) {
      if ((pages[id]?['sortIndex'] as num?)?.toInt() != sortIndex) {
        missing.add('page:$id');
      }
    }
    for (final id in editor.pagesDeleted) {
      if (pages.containsKey(id)) missing.add('page:$id');
    }
    if (editor.pageSettings case final settings?) {
      if (!_same(pages[_pageId(seed)]?['settings'], settings)) {
        missing.add('settings:${_pageId(seed)}');
      }
    }
    final rows = {
      for (final row in [
        ...(snapshot['elements'] as List).cast<Map>(),
        ...(snapshot['lineups'] as List).cast<Map>(),
      ])
        row['publicId'] as String: row,
    };
    final teammate = _teammateFields;
    for (final MapEntry(key: id, value: drawn) in editor.drawn.entries) {
      final row = rows[id];
      final payload = drawn.payload;
      if (payload == null) {
        if (row != null && row['deleted'] != true) missing.add(id);
        continue;
      }
      final expected = jsonDecode(jsonEncode(payload)) as Map;
      for (final field in (teammate[id] ?? const {}).entries) {
        (expected['data'] as Map)[field.key] = field.value;
      }
      if (row == null ||
          row['deleted'] == true ||
          !_same(row['payload'], expected) ||
          (row['sortIndex'] as num).toInt() != drawn.sortIndex) {
        missing.add(id);
      }
    }
    return missing;
  }

  Future<void> _finishSeed(int seed, Editor editor) async {
    await _settle(seed);
    final shown = await _check(seed, 'end of seed');
    if (shown != CloudSyncStatus.synced) {
      throw GauntletFailure(
        'not_synced_at_end',
        'Seed $seed ended with the chip showing $shown and '
            '${_app.queueState.pending.length} change(s) waiting: '
            '${_held()}',
      );
    }
    _recordAnswers();
    final snapshot = await _snapshot(seed);
    _progress.reports.add({
      ..._progress.current,
      'contentSha256': _contentHash(seed, snapshot),
    });
  }

  /// Counts the server's answers since the last count, and checks that it
  /// applied each op once: a second "applied" for one op id is a resend the
  /// server took as new work.
  void _recordAnswers() {
    final counts = _progress.current['answers'] as Map<String, Object?>;
    void count(String name) => counts[name] = (counts[name] as int) + 1;
    for (final batch in _app.transport.seen) {
      count('batches');
      if (!batch.delivered) count('lost');
      final ops = (batch.args['ops'] as List).cast<Map>();
      final results = (batch.result['results'] as List).cast<Map>();
      for (final (index, result) in results.indexed) {
        final op = ops[index];
        final subject = op['elementPublicId'] ??
            op['lineupPublicId'] ??
            op['pagePublicId'] ??
            'strategy';
        (_history[subject as String] ??= []).add(
          'round ${_progress.round} batch ${counts['batches']} '
          '${op['type']} at '
          '${op['expectedElementRevision'] ?? op['expectedLineupRevision'] ?? op['expectedStrategyRevision'] ?? op['expectedPageRevision'] ?? op['expectedPageContentRevision']} '
          '${(op['opId'] as String).substring(0, 8)}'
          '${op['merge'] == null ? '' : ' merged'}${batch.delivered ? '' : ' (answer lost)'}: '
          '${result['status']}${result['reason'] == null ? '' : ' ${result['reason']}'}'
          '${switch (result['appliedRevision'] ?? result['currentRevision']) {
            null => '',
            final revision => ' at $revision'
          }}',
        );
        final status = result['status'] as String;
        count(status);
        if (status != 'applied') continue;
        final opId = result['opId'] as String;
        if (!_progress.appliedOpIds.add(opId)) {
          throw GauntletFailure(
            'applied_twice',
            'The server applied op $opId twice',
          );
        }
      }
    }
    _app.transport.seen.clear();
  }

  /// A hash of what the user sees on the server: the strategy's name, its
  /// pages, and each item still there. Revisions and deleted rows are left
  /// out, since how edits were batched changes them and nothing a user sees.
  String _contentHash(int seed, Map<String, Object?> snapshot) {
    Object? local(Object? value) => switch (value) {
          final List<dynamic> list => list.map(local).toList(),
          final Map<dynamic, dynamic> map =>
            map.map((key, item) => MapEntry(key as String, local(item))),
          final String text => text.replaceAll(_prefix(seed), ''),
          final num number => number.toDouble(),
          _ => value,
        };
    List<Object?> live(String key) => [
          for (final row in (snapshot[key] as List).cast<Map>())
            if (row['deleted'] != true)
              {
                'id': row['publicId'],
                'payload': row['payload'],
                'sortIndex': row['sortIndex'],
              },
        ];
    final content = local({
      'name': (snapshot['header'] as Map)['name'],
      'pages': [
        for (final page in (snapshot['pages'] as List).cast<Map>())
          {
            'id': page['publicId'],
            'name': page['name'],
            'sortIndex': page['sortIndex'],
            'settings': page['settings'],
          },
      ],
      'elements': live('elements'),
      'lineups': live('lineups'),
    });
    return sha256
        .convert(utf8.encode(canonicalCloudJsonEncode(content)))
        .toString();
  }

  Future<Map<String, Object?>> _snapshot(int seed) async =>
      ((await _server.query('strategy:getFullSnapshot', {
        'clientProtocolVersion': cloudProtocolVersion,
        'strategyPublicId': strategyIdFor(seed),
        'acceptsTrashedPagesLeftOut': true,
        'acceptsPictureIds': true,
        'elementFieldLevel': 3,
      })) as Map)
          .cast<String, Object?>();

  static bool _same(Object? left, Object? right) =>
      cloudJsonEquivalent(_doubles(left), _doubles(right));

  static Object? _doubles(Object? value) => switch (value) {
        final num number => number.toDouble(),
        final List<dynamic> list => list.map(_doubles).toList(),
        final Map<dynamic, dynamic> map =>
          map.map((key, item) => MapEntry(key, _doubles(item))),
        _ => value,
      };

  Future<void> _waitFor(
    String what,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw GauntletFailure('timeout', 'Gave up waiting for $what');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Map<String, Object?> _newSeedReport(int seed) => {
        'seed': seed,
        'userEdits': 0,
        'faults': <String, Object?>{
          'delayedDelivery': false,
          'duplicatedDelivery': false,
          'lostAnswer': false,
          'lostRequest': false,
          'editedWhileResendWaits': false,
          'revisionConflictMerged': false,
          'revisionConflictRefused': false,
          'offlineQueuedEdits': false,
          'reconnect': false,
          'deleteRecreate': false,
          'deleteDuringSendSweep': false,
          'lostPageChangeAnswer': false,
          'editWhileAddAnswered': false,
          'authRefresh': false,
          'processRestart': false,
        },
        'auth': <String, Object?>{},
        'answers': <String, Object?>{
          'batches': 0,
          'lost': 0,
          'applied': 0,
          'noop': 0,
          'rejected': 0,
          'failed': 0,
        },
        'checks': <String, Object?>{},
        'teammateFields': <String, Object?>{},
      };

  Future<_Progress> _loadProgress() async {
    if (!await _progressFile.exists()) return _Progress();
    return _Progress.fromJson(
      (jsonDecode(await _progressFile.readAsString()) as Map)
          .cast<String, Object?>(),
    );
  }

  Future<void> _saveProgress() async {
    final next = File('${_progressFile.path}.next');
    await next.writeAsString(jsonEncode(_progress.toJson()), flush: true);
    await next.rename(_progressFile.path);
  }
}

/// A token the server refuses: unsigned and long expired.
const _rejectedToken =
    'eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJleHAiOjB9.rejected';

final class _Progress {
  _Progress();

  factory _Progress.fromJson(Map<String, Object?> json) => _Progress()
    ..seed = json['seed'] as int
    ..round = json['round'] as int
    ..seedStarted = json['seedStarted'] as bool
    ..didCheckpoint = json['didCheckpoint'] as bool
    ..tokenRefreshed = json['tokenRefreshed'] as bool
    ..processRestarts = json['processRestarts'] as int
    ..wallClockMs = json['wallClockMs'] as int
    ..editor = (json['editor'] as Map?)?.cast<String, Object?>()
    ..current = (json['current'] as Map).cast<String, Object?>()
    ..appliedOpIds.addAll((json['appliedOpIds'] as List).cast<String>())
    ..reports.addAll(
      (json['reports'] as List).map((report) => (report as Map).cast()),
    );

  int seed = 0;
  int round = 0;
  bool seedStarted = false;
  bool didCheckpoint = false;
  bool tokenRefreshed = false;
  int processRestarts = 0;
  int wallClockMs = 0;
  Map<String, Object?>? editor;
  Map<String, Object?> current = {};
  final Set<String> appliedOpIds = {};
  final List<Map<String, Object?>> reports = [];

  Map<String, Object?> toJson() => {
        'seed': seed,
        'round': round,
        'seedStarted': seedStarted,
        'didCheckpoint': didCheckpoint,
        'tokenRefreshed': tokenRefreshed,
        'processRestarts': processRestarts,
        'wallClockMs': wallClockMs,
        'editor': editor,
        'current': current,
        'appliedOpIds': appliedOpIds.toList(),
        'reports': reports,
      };
}
