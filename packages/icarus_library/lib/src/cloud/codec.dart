import 'package:collection/collection.dart';

import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import '../rows.dart';
import '../wire.dart';
import 'account.dart';
import 'events.dart';
import 'op_facts.dart';
import 'pending.dart';
import 'shown.dart';
import 'version.dart';

const cloudRowVersion = 1;

T? _named<T extends Enum>(JsonFields fields, String key, List<T> values) {
  final found = values.asNameMap()[fields.json[key]];
  if (found == null) fields.reject('expected "$key" to be a known name');
  return found;
}

void _versioned(JsonFields fields, String what) {
  if (fields.whole('version') != cloudRowVersion) {
    fields.reject('a $what version this build does not read');
  }
}

int _millis(DateTime time) => time.millisecondsSinceEpoch;

const _latestStoredTime = latestTime - 366 * Duration.millisecondsPerDay;

bool _isTime(Object? raw) =>
    raw is num && isSafeWhole(raw) && raw.abs() <= _latestStoredTime;

DateTime _timeAt(JsonFields fields, String key) => switch (fields.json[key]) {
  final num raw when _isTime(raw) => _time(raw),
  _ => () {
    fields.reject('a time out of range for "$key"');
    return DateTime.utc(1970);
  }(),
};

DateTime _time(num value) =>
    DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);

Map<String, Object?> entryToJson(QueueEntry entry) => switch (entry) {
  PendingOp() => {
    'version': cloudRowVersion,
    'kind': 'op',
    'op': entry.op.toJson(),
    'scope': switch (entry.scope) {
      StrategyWide() => {'strategy': true},
      OnPage(:final pagePublicId) => {'page': pagePublicId},
      Moving(:final from, :final to) => {'from': from, 'to': to},
    },
    'authored': switch (entry.authored) {
      final AuthoredRow row => _rowToJson(row),
      KeptOverServer(:final revision, :final life) => {
        'keptOverServer': revision,
        'life': ?life,
      },
      AuthoredNoRow(:final produces) => {
        'noRow': true,
        if (produces != null) 'produces': _producedToJson(produces),
      },
      AuthoredUnreadable() => {'unreadable': true},
    },
    'authoredIn': entry.authoredIn,
    'authoredAt': _millis(entry.authoredAt),
    'retriedAfter': entry.retriedAfter,
    'work': switch (entry.work) {
      OpWork() => 'op',
      CheckedDelete(:final seen) => {'checkedDelete': _seenToJson(seen)},
    },
    'refusal': switch (entry.refusal) {
      NotRefused() => null,
      RefusedWith(:final refusal) => _refusalToJson(refusal),
    },
    if (entry.window is WindowPassed) 'windowPassed': true,
    if (entry.behindOwn) 'behindOwn': true,
    if (entry.basis case final basis?)
      'basis': {
        'serverTime': basis.serverTime,
        'heldAtMicros': basis.heldAt.inMicroseconds,
      },
    'strategyLife': ?entry.strategyLife,
  },
  RetiredOp(:final opId, :final clientId, :final landing, :final stored) => {
    'version': cloudRowVersion,
    'kind': 'retired',
    'opId': opId,
    'clientId': clientId,
    'landing': landing.name,
    'stored': plainJson(stored),
  },
};

Map<String, Object?> _seenToJson(SeenPage seen) => {
  'pageDigest': seen.pageDigest,
  'pageRevision': seen.pageRevision,
  'content': switch (seen.content) {
    ContentNeverRead() => null,
    ContentSeen(:final digests) => [
      for (final MapEntry(:key, :value) in digests.entries) ['$key', value],
    ],
  },
};

int? _lifeOf(JsonFields fields) =>
    fields.has('life') ? fields.whole('life') : null;

Map<String, Object?> _rowToJson(AuthoredRow row) => {
  'revision': row.revision,
  'life': ?row.life,
  'digest': row.digest,
  'payloadVersion': ?row.payloadVersion,
  if (row.produces case final produces?) 'produces': _producedToJson(produces),
  if (row.movedRow case final moved?) 'movedRow': moved.toJson(),
};

Row? Function() _movedRowOf(JsonFields fields) {
  if (!fields.has('movedRow')) return () => null;
  final everywhere = RowSpot(names: (_) => true);
  final admitted = admit(canonicalJson(fields.json['movedRow']));
  final Row? row = switch (ElementRow.parse(
    admitted,
    spot: everywhere,
    page: everywhere,
    canRead: (_) => true,
  )) {
    Placed(row: final LiveElement row) => row,
    _ => switch (LineupGroupRow.parse(
      admitted,
      spot: everywhere,
      page: everywhere,
      strategy: everywhere,
      canRead: (_) => true,
    )) {
      Placed(row: final LiveLineupGroup row) => row,
      _ => null,
    },
  };
  if (row == null) fields.reject('an unreadable moved row');
  return () => row;
}

Map<String, Object?> _producedToJson(ProducedRow row) => {
  'page': ?row.page,
  'revision': row.revision,
  'life': ?row.life,
  'digest': row.digest,
  if (!row.justifies) 'justifies': false,
};

Decoded<ProducedRow> _producedRow(Object? json) =>
    JsonFields.read(json, 'produced row', (fields) {
      final page = switch (fields.json['page']) {
        null => null,
        final String page => page,
        _ => () {
          fields.reject('an unreadable page');
          return null;
        }(),
      };
      final revision = fields.whole('revision');
      if (revision < 1) fields.reject('revisions start at 1');
      final digest = fields.string('digest');
      final life = _lifeOf(fields);
      final justifies = switch (fields.json['justifies']) {
        null => true,
        false => false,
        _ => () {
          fields.reject('an unreadable flag');
          return true;
        }(),
      };
      return () => ProducedRow(
        page: page,
        revision: revision,
        life: life,
        digest: digest,
        justifies: justifies,
      );
    });

ProducedRow? Function() _producesOfKey(JsonFields fields, String key) {
  if (!fields.has(key)) return () => null;
  final produces = fields.decoded(key, _producedRow);
  return () => produces;
}

Map<String, Object?> _refusalToJson(ServerRefusal refusal) => switch (refusal) {
  RejectedByServer(:final reason, :final current) => {
    'rejected': reason.wireName,
    if (current case ServerSnapshot(
      :final target,
      :final revision,
      :final life,
      :final value,
    ))
      'current': {
        'target': target.name,
        'revision': revision,
        'life': ?life,
        'value': value.toJson(),
      },
  },
  AnsweredWithoutLife(:final revision) => {'withoutLife': revision ?? true},
  FailedOnServer(:final code, :final message) => {
    'failed': '$code',
    'message': message,
  },
};

Decoded<QueueEntry> decodeEntry(
  int place,
  Object? json, {
  required bool sendable,
}) => JsonFields.read(json, 'pending entry', (fields) {
  _versioned(fields, 'entry');
  switch (fields.json['kind']) {
    case 'retired':
      final opId = fields.string('opId');
      final clientId = fields.string('clientId');
      final landing = _named(fields, 'landing', Landing.values);
      final stored = fields.json['stored'];
      return () => RetiredOp(
        place: place,
        opId: opId,
        clientId: clientId,
        landing: landing!,
        stored: plainJson(stored),
      );
    case 'op':
      final op = fields.decoded('op', StrategyOp.decode);
      final scope = fields.decoded('scope', _scope);
      final authored = fields.decoded('authored', _authored);
      final authoredIn = fields.whole('authoredIn');
      final authoredAt = _timeAt(fields, 'authoredAt');
      if (authoredIn < 0) fields.reject('a negative session number');
      final retriedAfter = fields.whole('retriedAfter');
      if (retriedAfter < 0) fields.reject('a negative attempt number');
      final refused = fields.json['refusal'] == null
          ? null
          : fields.decoded('refusal', _refusal);
      final windowPassed = switch (fields.json['windowPassed']) {
        null => false,
        true => true,
        _ => () {
          fields.reject('an unreadable window');
          return false;
        }(),
      };
      final Work? work = switch ((fields.json['work'], op)) {
        ('op', final op?) => OpWork(op),
        ({'checkedDelete': final Object? check}, final PageDeleteOp delete) =>
          switch (_seen(adoptJson(check))) {
            Read(:final value) => CheckedDelete(delete, value),
            CouldNotRead() => null,
          },
        _ => null,
      };
      if (work == null) fields.reject('work that does not fit its op');
      if (sendable && op != null && scope != null && !_scopeFits(op, scope)) {
        fields.reject('a scope or field base that does not fit its op');
      }
      final strategyLife = fields.has('strategyLife')
          ? fields.whole('strategyLife')
          : null;
      final behindOwn = switch (fields.json['behindOwn']) {
        null => false,
        true => true,
        _ => () {
          fields.reject('an unreadable flag');
          return false;
        }(),
      };
      final basis = switch (fields.json['basis']) {
        null => null,
        {
          'serverTime': final int serverTime,
          'heldAtMicros': final int heldAt,
        } =>
          ServerTimeBasis(serverTime, heldAt: Duration(microseconds: heldAt)),
        _ => () {
          fields.reject('an unreadable basis');
          return null;
        }(),
      };
      return () => PendingOp(
        basis: basis,
        behindOwn: behindOwn,
        place: place,
        work: work!,
        scope: scope!,
        authored: authored!,
        authoredIn: authoredIn,
        authoredAt: authoredAt,
        refusal: refused == null ? const NotRefused() : RefusedWith(refused),
        retriedAfter: retriedAfter,
        window: windowPassed ? const WindowPassed() : const WindowOpen(),
        strategyLife: strategyLife,
      );
    default:
      fields.reject('an entry kind this build does not read');
      return () => throw StateError('rejected');
  }
});

bool _scopeFits(StrategyOp op, Scope scope) => switch (editOf(
  op,
  authored: const AuthoredNoRow(),
  rowPage: switch (scope) {
    OnPage(:final pagePublicId) => pagePublicId,
    Moving(:final from) => from,
    StrategyWide() => null,
  },
)) {
  EditMade(:final edit) => edit.scope == scope,
  NeedsPageDeleteEdit(:final op) => scope == OnPage(op.pagePublicId),
  NeedsRowPage() || NeedsFieldBase() || CopyMustBeExpanded() => false,
};

Decoded<Scope> _scope(Object? json) => JsonFields.read(json, 'scope', (fields) {
  if (fields.has('page')) {
    final page = fields.string('page');
    return () => OnPage(page);
  }
  if (fields.has('from')) {
    final from = fields.string('from');
    final to = fields.string('to');
    return () => Moving(from: from, to: to);
  }
  if (fields.json['strategy'] != true) fields.reject('expected a scope');
  return () => const StrategyWide();
});

Decoded<Authored> _authored(Object? json) =>
    JsonFields.read(json, 'authored', (fields) {
      if (fields.json['noRow'] == true) {
        final produces = _producesOfKey(fields, 'produces');
        return () => AuthoredNoRow(produces: produces());
      }
      if (fields.json['unreadable'] == true) {
        return () => const AuthoredUnreadable();
      }
      if (fields.has('keptOverServer')) {
        final revision = fields.whole('keptOverServer');
        if (revision < 1) fields.reject('revisions start at 1');
        final life = _lifeOf(fields);
        return () => KeptOverServer(revision, life: life);
      }
      return _authoredRowOf(fields);
    });

AuthoredRow Function() _authoredRowOf(JsonFields fields) {
  final revision = fields.whole('revision');
  final life = _lifeOf(fields);
  final digest = fields.string('digest');
  final payloadVersion = fields.has('payloadVersion')
      ? fields.whole('payloadVersion')
      : null;
  final produces = _producesOfKey(fields, 'produces');
  final movedRow = _movedRowOf(fields);
  return () => AuthoredRow(
    revision: revision,
    life: life,
    digest: digest,
    payloadVersion: payloadVersion,
    produces: produces(),
    movedRow: movedRow(),
  );
}

SeenPart? _part(Object? name) => switch (name) {
  'settings' => const SeenSettings(),
  final String name when name.startsWith('element:') => SeenElement(
    name.substring('element:'.length),
  ),
  final String name when name.startsWith('lineup:') => SeenLineupGroup(
    name.substring('lineup:'.length),
  ),
  _ => null,
};

Map<SeenPart, String>? _digests(Object? raw) {
  if (raw is! List<Object?>) return null;
  final digests = <SeenPart, String>{};
  for (final pair in raw) {
    if (pair case [final Object? name, final String digest]) {
      final part = _part(name);
      if (part == null || digests.containsKey(part)) return null;
      digests[part] = digest;
    } else {
      return null;
    }
  }
  return digests;
}

Decoded<SeenPage> _seen(Object? json) => JsonFields.read(json, 'seen page', (
  fields,
) {
  final pageDigest = fields.string('pageDigest');
  final pageRevision = fields.whole('pageRevision');
  final content = fields.json['content'];
  final digests = content == null ? null : _digests(content);
  if (content != null && digests == null) {
    fields.reject('unreadable seen content');
  }
  return () => SeenPage(
    pageDigest: pageDigest,
    pageRevision: pageRevision,
    content: digests == null ? const ContentNeverRead() : ContentSeen(digests),
  );
});

Decoded<ServerRefusal> _refusal(Object? json) =>
    JsonFields.read(json, 'refusal', (fields) {
      if (fields.has('rejected')) {
        final reason = RejectionReason.values
            .where((reason) => reason.wireName == fields.json['rejected'])
            .firstOrNull;
        if (reason == null) fields.reject('an unknown rejection');
        final ServerCopy current = switch (fields.json['current']) {
          {
                    'target': final String target,
                    'revision': final num revision,
                    'value': final Map<String, Object?> value,
                  } &&
                  final copy
              when isSafeWhole(revision) &&
                  SnapshotTarget.values.asNameMap().containsKey(target) &&
                  (copy['life'] == null || isSafeWhole(copy['life'])) =>
            ServerSnapshot(
              target: SnapshotTarget.values.asNameMap()[target]!,
              revision: revision.toInt(),
              life: (copy['life'] as num?)?.toInt(),
              value: value,
            ),
          null => const NoServerCopy(),
          _ => () {
            fields.reject('an unreadable server copy');
            return const NoServerCopy();
          }(),
        };
        return () => RejectedByServer(reason!, current);
      }
      if (fields.has('withoutLife')) {
        final revision = switch (fields.json['withoutLife']) {
          true => null,
          _ => fields.whole('withoutLife'),
        };
        return () => AnsweredWithoutLife(revision);
      }
      final code = fields.string('failed');
      final message = fields.string('message');
      return () => FailedOnServer(switch (FailureCode.values
          .where((known) => known.wireName == code)
          .firstOrNull) {
        final known? => KnownFailure(known),
        null => OtherFailure(code),
      }, message);
    });

sealed class EntriesReading {
  const EntriesReading();
}

final class EntriesRead extends EntriesReading {
  EntriesRead(List<QueueEntry> entries) : entries = List.unmodifiable(entries);

  final List<QueueEntry> entries;
}

final class EntriesUnreadable extends EntriesReading {
  const EntriesUnreadable(this.place, this.problem);

  final int place;
  final String problem;
}

EntriesReading entriesFrom(Iterable<(int, String)> stored) {
  final seen = <String>{};
  final entries = <QueueEntry>[];
  for (final (place, text) in [
    ...stored,
  ]..sort((a, b) => a.$1.compareTo(b.$1))) {
    final reading = _fromText(
      text,
      (json) => decodeEntry(place, json, sendable: true),
    );
    switch (reading) {
      case CloudRowRead(value: final entry) when seen.add(entry.id):
        entries.add(entry);
      case CloudRowRead():
        return EntriesUnreadable(place, 'an op id another entry already holds');
      case CloudRowUnreadable(:final problem):
        return EntriesUnreadable(place, problem);
    }
  }
  return EntriesRead(entries);
}

Map<String, Object?> attemptToJson(AttemptFact attempt) => {
  'version': cloudRowVersion,
  'clientId': attempt.clientId,
  'build': attempt.build,
  'at': _millis(attempt.at),
  'ops': [for (final op in attempt.ops) op.toJson()],
  'outcome': switch (attempt.outcome) {
    AttemptOpen() => 'open',
    AttemptReleased() => 'released',
    AttemptFailed(:final cause, :final at) => {
      'failed': switch (cause) {
        TransportCut(:final failure) => failure.name,
        AppClosedWhileSending() => 'appClosed',
      },
      'at': _millis(at),
    },
    AttemptRefusedWhole(:final refusal, :final at) => {
      'refused': refusal.name,
      'at': ?switch (at) {
        final at? => _millis(at),
        null => null,
      },
    },
  },
};

sealed class CloudRowReading<T> {
  const CloudRowReading();
}

final class CloudRowRead<T> extends CloudRowReading<T> {
  const CloudRowRead(this.value);

  final T value;
}

final class CloudRowUnreadable<T> extends CloudRowReading<T> {
  const CloudRowUnreadable(this.problem);

  final String problem;
}

CloudRowReading<T> _fromText<T>(
  String text,
  Decoded<T> Function(Object? json) decode,
) => switch (admit(text)) {
  NotAdmitted(:final problem) => CloudRowUnreadable(problem),
  Admitted(:final json) => switch (decode(json)) {
    Read(:final value) => CloudRowRead(value),
    CouldNotRead(:final problem) => CloudRowUnreadable(problem),
  },
};

AttemptOutcome? _outcome(Object? raw) => switch (raw) {
  'open' => const AttemptOpen(),
  'released' => const AttemptReleased(),
  {'failed': 'appClosed', 'at': final num at} when _isTime(at) => AttemptFailed(
    const AppClosedWhileSending(),
    _time(at),
  ),
  {'failed': final String name, 'at': final num at}
      when _isTime(at) &&
          TransportFailure.values.asNameMap().containsKey(name) =>
    AttemptFailed(
      TransportCut(TransportFailure.values.asNameMap()[name]!),
      _time(at),
    ),
  {'refused': final String name, 'at': final num at}
      when BatchRefusal.values.asNameMap().containsKey(name) && _isTime(at) =>
    AttemptRefusedWhole(BatchRefusal.values.asNameMap()[name]!, at: _time(at)),
  {'refused': final String name}
      when BatchRefusal.values.asNameMap().containsKey(name) =>
    AttemptRefusedWhole(BatchRefusal.values.asNameMap()[name]!),
  _ => null,
};

CloudRowReading<AttemptFact> attemptFromText(int number, String text) =>
    _fromText(
      text,
      (json) => JsonFields.read(json, 'attempt', (fields) {
        _versioned(fields, 'attempt');
        if (number < 1) fields.reject('attempts are numbered from 1');
        final clientId = fields.string('clientId');
        final build = fields.string('build');
        final at = _timeAt(fields, 'at');
        final ops = <StrategyOp>[];
        final ids = <String>{};
        if (fields.json['ops'] case final List<Object?> list
            when list.isNotEmpty) {
          for (final raw in list) {
            switch (StrategyOp.decode(adoptJson(raw))) {
              case Read(:final value) when ids.add(value.opId):
                ops.add(value);
              case Read():
                fields.reject('an op sent twice in one attempt');
              case CouldNotRead(:final problem):
                fields.reject(problem);
            }
          }
        } else {
          fields.reject('expected the ops it sent');
        }
        final outcome = _outcome(fields.json['outcome']);
        if (outcome == null) {
          fields.reject('an attempt outcome this build does not read');
        }
        return () => AttemptFact(
          number: number,
          clientId: clientId,
          build: build,
          at: at,
          ops: ops,
          outcome: outcome!,
        );
      }),
    );

final class CloudFacts {
  const CloudFacts(this.owner, this.facts);

  final Account owner;
  final StrategyFacts facts;

  @override
  bool operator ==(Object other) =>
      other is CloudFacts && other.owner == owner && other.facts == facts;

  @override
  int get hashCode => Object.hash(owner, facts);
}

Map<String, Object?> factsToJson(Account owner, StrategyFacts facts) => {
  'version': cloudRowVersion,
  'account': owner.subject,
  'presence': facts.presence.name,
  'accessLostAt': facts.accessLostAt,
  'accessConfirmedAt': facts.accessConfirmedAt,
  if (facts.upgradeTold case UpgradeToldTo(:final build, :final attempt))
    'upgradeTold': {'build': build, 'attempt': attempt},
  if (facts.setAside case SetAside(:final generations))
    'setAside': [
      for (final SetAsideGeneration(:writtenIn, :replacedBy, :entries)
          in generations)
        {
          'writtenIn': ?writtenIn,
          'replacedBy': replacedBy,
          'entries': [
            for (final entry in entries)
              {'place': entry.place, 'entry': entryToJson(entry)},
          ],
        },
    ],
  if (facts.base case BaseDisagreed(:final reason, :final tried))
    'base': {
      'state': switch (facts.base) {
        BaseRereading() => 'rereading',
        _ => 'held',
      },
      'reason': reason,
      'tried': tried,
    },
};

CloudOwner ownerFromText(String text) => switch (admit(text)) {
  NotAdmitted() => const OwnerUnreadable(),
  Admitted(:final json) => switch (JsonFields.read(json, 'cloud facts', (
    fields,
  ) {
    final account = fields.string('account');
    if (account.isEmpty) fields.reject('expected the account the work is for');
    return () => account;
  })) {
    Read(:final value) => OwnedBy(Account(value)),
    CouldNotRead() => const OwnerUnreadable(),
  },
};

CloudRowReading<CloudFacts> factsFromText(String text) => _fromText(
  text,
  (json) => JsonFields.read(json, 'cloud facts', (fields) {
    _versioned(fields, 'cloud facts');
    final account = fields.string('account');
    if (account.isEmpty) fields.reject('expected the account the work is for');
    final presence = _named(fields, 'presence', Presence.values);
    final lost = fields.whole('accessLostAt');
    final confirmed = fields.whole('accessConfirmedAt');
    if (lost < 0 || confirmed < 0) fields.reject('a negative attempt number');
    final UpgradeTold upgrade = switch (fields.json['upgradeTold']) {
      null => const NoUpgradeTold(),
      {'build': final String build, 'attempt': final num attempt}
          when isSafeWhole(attempt) && attempt >= 0 =>
        UpgradeToldTo(build, attempt: attempt.toInt()),
      _ => () {
        fields.reject('an unreadable upgrade request');
        return const NoUpgradeTold();
      }(),
    };
    final setAside = switch (fields.json['setAside']) {
      null => const NothingSetAside(),
      final Object raw => _setAside(raw),
    };
    if (setAside == null) fields.reject('an unreadable set-aside record');
    final BaseState? base = switch (fields.json['base']) {
      null => const BaseAgrees(),
      {
        'state': final String state,
        'reason': final String reason,
        'tried': final List<Object?> tried,
      }
          when tried.isNotEmpty && tried.every((build) => build is String) =>
        switch (state) {
          'rereading' => BaseRereading(reason, tried: tried.cast()),
          'held' => BaseHeld(reason, tried: tried.cast()),
          _ => null,
        },
      _ => null,
    };
    if (base == null) fields.reject('an unreadable base state');
    return () => CloudFacts(
      Account(account),
      StrategyFacts(
        presence: presence!,
        accessLostAt: lost,
        accessConfirmedAt: confirmed,
        upgradeTold: upgrade,
        setAside: setAside!,
        base: base!,
      ),
    );
  }),
);

SetAside? _setAside(Object raw) {
  if (raw is! List<Object?> || raw.isEmpty) return null;
  final generations = <SetAsideGeneration>[];
  for (final each in raw) {
    final generation = each == null ? null : _generation(each);
    if (generation == null) return null;
    generations.add(generation);
  }
  return SetAside(generations);
}

SetAsideGeneration? _generation(Object raw) {
  if (raw case {
    'replacedBy': final num replacedBy,
    'entries': final List<Object?> stored,
  } when isSafeWhole(replacedBy)) {
    final writtenIn = raw['writtenIn'];
    if (writtenIn != null && !isSafeWhole(writtenIn)) return null;
    final entries = <QueueEntry>[];
    for (final each in stored) {
      if (each case {
        'place': final num place,
        'entry': final Object? json,
      } when isSafeWhole(place)) {
        switch (decodeEntry(place.toInt(), json, sendable: false)) {
          case Read(:final value):
            entries.add(value);
          case CouldNotRead():
            return null;
        }
      } else {
        return null;
      }
    }
    return SetAsideGeneration(
      writtenIn: (writtenIn as num?)?.toInt(),
      replacedBy: replacedBy.toInt(),
      entries: entries,
    );
  }
  return null;
}

final class Counters {
  const Counters({required this.nextAttempt, required this.nextSession});

  final int nextAttempt;
  final int nextSession;

  @override
  bool operator ==(Object other) =>
      other is Counters &&
      other.nextAttempt == nextAttempt &&
      other.nextSession == nextSession;

  @override
  int get hashCode => Object.hash(nextAttempt, nextSession);
}

Map<String, Object?> countersToJson(Counters counters) => {
  'version': cloudRowVersion,
  'nextAttempt': counters.nextAttempt,
  'nextSession': counters.nextSession,
};

CloudRowReading<Counters> countersFromText(String text) => _fromText(
  text,
  (json) => JsonFields.read(json, 'counters', (fields) {
    _versioned(fields, 'counters');
    final nextAttempt = fields.whole('nextAttempt');
    final nextSession = fields.whole('nextSession');
    if (nextAttempt < 1 || nextSession < 1) {
      fields.reject('counters start at 1');
    }
    return () => Counters(nextAttempt: nextAttempt, nextSession: nextSession);
  }),
);

Map<String, Object?> landedToJson(LandedWork work) => {
  'version': cloudRowVersion,
  'op': work.op.toJson(),
  'revision': work.revision,
  'life': ?work.life,
  'shape': work.shape.name,
  'own': work.own,
  'firstSentAt': _millis(work.firstSentAt),
  if (work.produced case final produced?) 'produced': _producedToJson(produced),
  if (work.movedRow case final moved?) 'movedRow': moved.toJson(),
  if (work.shownWithout) 'shownWithout': true,
  if (work.answeredAt != ReadStart.beforeAnyRead)
    'answeredAt': _startToJson(work.answeredAt),
};

CloudRowReading<LandedWork> landedFromText(
  int attempt,
  int position,
  String text,
) => _fromText(
  text,
  (json) => JsonFields.read(json, 'landed work', (fields) {
    _versioned(fields, 'landed work');
    if (attempt < 1 || position < 0) fields.reject('an impossible landing');
    final op = fields.decoded('op', StrategyOp.decode);
    final revision = fields.whole('revision');
    if (revision < 1) fields.reject('revisions start at 1');
    final life = _lifeOf(fields);
    final shape = _named(fields, 'shape', LandedShape.values);
    final own = switch (fields.json['own']) {
      final bool own => own,
      _ => () {
        fields.reject('expected whether the write was this device\'s');
        return false;
      }(),
    };
    final firstSentAt = _timeAt(fields, 'firstSentAt');
    final movedRow = _movedRowOf(fields);
    final produced = _producesOfKey(fields, 'produced');
    final shownWithout = switch (fields.json['shownWithout']) {
      null => false,
      true => true,
      _ => () {
        fields.reject('an unreadable flag');
        return false;
      }(),
    };
    final answeredAt = fields.has('answeredAt')
        ? _startFrom(fields.json['answeredAt'])
        : ReadStart.beforeAnyRead;
    if (answeredAt == null) fields.reject('an unreadable answer point');
    return () => LandedWork(
      answeredAt: answeredAt!,
      own: own,
      firstSentAt: firstSentAt,
      movedRow: movedRow(),
      produced: produced(),
      shownWithout: shownWithout,
      attempt: attempt,
      position: position,
      op: op!,
      revision: revision,
      life: life,
      shape: shape!,
    );
  }),
);

String _targetKey(Target target) => switch (target) {
  StrategyTarget() => 'strategy',
  PageTarget(:final pagePublicId) => 'page:$pagePublicId',
  SettingsTarget(:final pagePublicId) => 'settings:$pagePublicId',
  ElementTarget(:final elementPublicId) => 'element:$elementPublicId',
  LineupTarget(:final lineupPublicId) => 'lineup:$lineupPublicId',
};

Target? _target(Object? key) => switch (key) {
  'strategy' => const StrategyTarget(),
  final String key when key.startsWith('page:') => PageTarget(
    key.substring('page:'.length),
  ),
  final String key when key.startsWith('settings:') => SettingsTarget(
    key.substring('settings:'.length),
  ),
  final String key when key.startsWith('element:') => ElementTarget(
    key.substring('element:'.length),
  ),
  final String key when key.startsWith('lineup:') => LineupTarget(
    key.substring('lineup:'.length),
  ),
  _ => null,
};

List<Object?> _shownRow(String key, ShownRow row) => [
  key,
  row.page,
  row.revision,
  row.digest,
];

(String, ShownRow)? _shownRowFrom(Object? raw) => switch (raw) {
  [
    final String key,
    final String page,
    final Object? revision,
    final String digest,
  ]
      when revision == null || (revision is num && isSafeWhole(revision)) =>
    (
      key,
      ShownRow(
        page: page,
        revision: (revision as num?)?.toInt(),
        digest: digest,
      ),
    ),
  _ => null,
};

Map<String, int> _livesOf(Map<String, ShownRow> rows) => {
  for (final MapEntry(:key, :value) in rows.entries) key: ?value.life,
};

Map<String, int>? _livesFrom(Object? raw) => switch (raw) {
  null => const {},
  final Map<String, Object?> lives
      when lives.values.every((life) => life is num && isSafeWhole(life)) =>
    {
      for (final MapEntry(:key, :value) in lives.entries)
        key: (value! as num).toInt(),
    },
  _ => null,
};

Map<String, ShownRow> _withLives(
  Map<String, ShownRow> rows,
  Map<String, int> lives,
) => {
  for (final MapEntry(:key, :value) in rows.entries)
    key: ShownRow(
      page: value.page,
      revision: value.revision,
      digest: value.digest,
      life: lives[key],
    ),
};

Map<String?, Map<String, Object?>> shownToGroups(Shown shown) {
  final byPage = _rowsByPage(shown);
  return {
    null: _headerGroup(shown),
    for (final page in _groupPages(shown, byPage))
      page: _pageGroup(shown, page, byPage[page] ?? const []),
  };
}

Map<String?, Map<String, Object?>?> shownToGroupsSince(
  Shown before,
  Shown after, {
  required bool Function(String? group) kept,
}) {
  final beforeByPage = _rowsByPage(before);
  final afterByPage = _rowsByPage(after);
  return {
    null: kept(null) && _sameHeader(before, after) ? null : _headerGroup(after),
    for (final page in _groupPages(after, afterByPage))
      page:
          kept(page) &&
              _samePage(before, after, page, beforeByPage, afterByPage)
          ? null
          : _pageGroup(after, page, afterByPage[page] ?? const []),
  };
}

typedef _PageRows = List<(Target, ShownRow)>;

Map<String, _PageRows> _rowsByPage(Shown shown) {
  final byPage = <String, _PageRows>{};
  for (final MapEntry(:key, :value) in shown.rows.entries) {
    (byPage[value.page] ??= []).add((key, value));
  }
  return byPage;
}

Set<String> _groupPages(Shown shown, Map<String, _PageRows> byPage) => {
  ...shown.content.keys,
  ...byPage.keys,
  for (final MapEntry(:key, :value) in shown.pageReads.entries)
    if (isDebt(value)) key,
};

bool _sameInOrder<K, V>(Map<K, V>? left, Map<K, V>? right) {
  if (identical(left, right)) return true;
  if (left == null || right == null || left.length != right.length) {
    return false;
  }
  final others = right.entries.iterator;
  for (final MapEntry(:key, :value) in left.entries) {
    others.moveNext();
    if (others.current.key != key || others.current.value != value) {
      return false;
    }
  }
  return true;
}

bool _sameHeader(Shown before, Shown after) =>
    before.strategy == after.strategy &&
    before.list == after.list &&
    _sameInOrder(before.pages, after.pages) &&
    _sameInOrder(before.settings, after.settings) &&
    _sameInOrder(before.highest, after.highest);

bool _samePage(
  Shown before,
  Shown after,
  String page,
  Map<String, _PageRows> beforeByPage,
  Map<String, _PageRows> afterByPage,
) =>
    before.pageRead(page) == after.pageRead(page) &&
    _sameInOrder(before.content[page], after.content[page]) &&
    const ListEquality<(Target, ShownRow)>().equals(
      beforeByPage[page] ?? const [],
      afterByPage[page] ?? const [],
    );

Map<String, Object?> _headerGroup(Shown shown) => {
  'version': cloudRowVersion,
  'strategy': [
    if (shown.strategy case final strategy?) _shownRow('strategy', strategy),
  ],
  'pages': [
    for (final MapEntry(:key, :value) in shown.pages.entries)
      _shownRow(key, value),
  ],
  'settings': [
    for (final MapEntry(:key, :value) in shown.settings.entries)
      _shownRow(key, value),
  ],
  'highest': [
    for (final MapEntry(:key, :value) in shown.highest.entries)
      [_targetKey(key), value.revisionOnTheWire],
  ],
  'lives': ?_unlessEmpty({
    'strategy': _livesOf({'strategy': ?shown.strategy}),
    'pages': _livesOf(shown.pages),
    'settings': _livesOf(shown.settings),
    'highest': {
      for (final MapEntry(:key, :value) in shown.highest.entries)
        _targetKey(key): ?value.lifeOnTheWire,
    },
  }),
  'read': ?_readToJson(shown.list),
};

Map<String, Object?> _pageGroup(Shown shown, String page, _PageRows rows) => {
  'version': cloudRowVersion,
  'page': page,
  'content': switch (shown.content[page]) {
    null => null,
    final content => [
      for (final MapEntry(:key, :value) in content.entries) ['$key', value],
    ],
  },
  'rows': [for (final (key, value) in rows) _shownRow(_targetKey(key), value)],
  'lives': ?_unlessEmpty({
    for (final (key, value) in rows) _targetKey(key): ?value.life,
  }),
  'read': ?_readToJson(shown.pageRead(page)),
};

Object? _readToJson(ReadState state) => switch (state) {
  ReadOwed(:final unlessLife, :final namedLife, :final since) => {
    'owedSince': _startToJson(since),
    'unless': ?unlessLife,
    'named': ?namedLife,
  },
  ReadRefused(
    :final problem,
    :final unlessLife,
    :final namedLife,
    :final since,
  ) =>
    {
      'refused': problem,
      'unless': ?unlessLife,
      'named': ?namedLife,
      'since': _startToJson(since),
    },
  NotReadThisSession() || ReadThisSession() => null,
};

Map<String, Object?> _startToJson(ReadStart start) => {
  'session': start.session,
  'step': start.sequence,
};

ReadStart? _startFrom(Object? raw) => switch (raw) {
  {'session': final num session, 'step': final num step}
      when raw.length == 2 &&
          isSafeWhole(session) &&
          isSafeWhole(step) &&
          session >= 0 &&
          step >= 0 =>
    ReadStart(session: session.toInt(), sequence: step.toInt()),
  _ => null,
};

int? _namedFrom(Map<Object?, Object?> raw) => switch (raw['named']) {
  final num life when isSafeWhole(life) => life.toInt(),
  _ => null,
};

ReadState? _readFrom(Object? raw) => switch (raw) {
  {'named': final Object? named} when named is! num || !isSafeWhole(named) =>
    null,
  {'owedSince': _, 'named': _} => switch (_readFrom({
    for (final MapEntry(:key, :value) in raw.entries)
      if (key != 'named') key: value,
  })) {
    ReadOwed(:final unlessLife, :final since) => ReadOwed(
      unlessLife: unlessLife,
      namedLife: _namedFrom(raw),
      since: since,
    ),
    _ => null,
  },
  {'refused': _, 'named': _} => switch (_readFrom({
    for (final MapEntry(:key, :value) in raw.entries)
      if (key != 'named') key: value,
  })) {
    ReadRefused(:final problem, :final unlessLife, :final since) => ReadRefused(
      problem,
      unlessLife: unlessLife,
      namedLife: _namedFrom(raw),
      since: since,
    ),
    _ => null,
  },
  null => const NotReadThisSession(),
  'owed' => const ReadOwed(since: ReadStart.beforeAnyRead),
  {'owedUnless': final num life} when isSafeWhole(life) && raw.length == 1 =>
    ReadOwed(unlessLife: life.toInt(), since: ReadStart.beforeAnyRead),
  {'owedSince': final Object? since} => switch ((
    _startFrom(since),
    raw['unless'],
    raw.length,
  )) {
    (final since?, null, 1) => ReadOwed(since: since),
    (final since?, final num life, 2) when isSafeWhole(life) => ReadOwed(
      unlessLife: life.toInt(),
      since: since,
    ),
    _ => null,
  },
  {'refused': final String problem} => switch ((
    raw.containsKey('since')
        ? _startFrom(raw['since'])
        : ReadStart.beforeAnyRead,
    raw['unless'],
    raw.containsKey('unless'),
  )) {
    (final since?, null, false) => ReadRefused(problem, since: since),
    (final since?, final num life, true) when isSafeWhole(life) => ReadRefused(
      problem,
      unlessLife: life.toInt(),
      since: since,
    ),
    _ => null,
  },
  _ => null,
};

Map<String, Object?>? _unlessEmpty(Map<String, Object?> lives) =>
    lives.values.every((value) => value is Map && value.isEmpty) ||
        lives.isEmpty
    ? null
    : lives;

sealed class ShownReading {
  const ShownReading();
}

final class ShownRead extends ShownReading {
  const ShownRead(this.shown);

  final Shown shown;
}

final class ShownUnreadable extends ShownReading {
  const ShownUnreadable(this.page, this.problem);

  final String? page;
  final String problem;
}

ShownReading shownFromGroups(Map<String?, String> texts) {
  ShownRow? strategy;
  final pages = <String, ShownRow>{};
  final settings = <String, ShownRow>{};
  final highest = <Target, Version>{};
  final content = <String, Map<SeenPart, String>>{};
  final rows = <Target, ShownRow>{};
  ReadState list = const NotReadThisSession();
  final pageReads = <String, ReadState>{};
  for (final MapEntry(key: group, value: text) in texts.entries) {
    final reading = _fromText<void>(
      text,
      (json) => JsonFields.read(json, 'shown results', (fields) {
        _versioned(fields, 'shown results');
        if (group == null) {
          final lives = switch (fields.json['lives']) {
            null => const <String, Object?>{},
            final Map<String, Object?> lives => lives,
            _ => null,
          };
          if (lives == null) fields.reject('unreadable lives');
          final strategyLives = _livesFrom(lives?['strategy']);
          final pageLives = _livesFrom(lives?['pages']);
          final settingsLives = _livesFrom(lives?['settings']);
          final highestLives = _livesFrom(lives?['highest']);
          if (strategyLives == null ||
              pageLives == null ||
              settingsLives == null ||
              highestLives == null) {
            fields.reject('unreadable lives');
          }
          final strategyRows = _shownRows(fields.json['strategy']);
          if (strategyRows == null ||
              strategyRows.keys.any((key) => key != 'strategy')) {
            fields.reject('an unreadable strategy row');
          }
          final owed = _readFrom(fields.json['read']);
          if (owed == null) fields.reject('an unreadable page list debt');
          final pageRows = _shownRows(fields.json['pages']);
          final settingsRows = _shownRows(fields.json['settings']);
          final tops = _highest(fields.json['highest']);
          if (pageRows == null || settingsRows == null || tops == null) {
            fields.reject('unreadable shown rows');
          }
          return () {
            list = owed!;
            strategy = _withLives(strategyRows!, strategyLives!)['strategy'];
            pages.addAll(_withLives(pageRows!, pageLives!));
            settings.addAll(_withLives(settingsRows!, settingsLives!));
            highest.addAll({
              for (final MapEntry(:key, :value) in tops!.entries)
                key: Version(
                  value.revisionOnTheWire,
                  life: highestLives![_targetKey(key)],
                ),
            });
          };
        }
        if (fields.json['page'] != group) fields.reject('another page');
        final pageOwed = _readFrom(fields.json['read']);
        if (pageOwed == null) fields.reject('an unreadable page debt');
        final raw = fields.json['content'];
        final digests = raw == null ? null : _digests(raw);
        if (raw != null && digests == null) {
          fields.reject('unreadable shown content');
        }
        final rowLives = _livesFrom(fields.json['lives']);
        if (rowLives == null) fields.reject('unreadable lives');
        final read = _shownRows(fields.json['rows']);
        final found = read == null
            ? null
            : _withLives(read, rowLives ?? const {});
        final targets = found == null
            ? null
            : {
                for (final MapEntry(:key, :value) in found.entries)
                  _target(key): value,
              };
        if (targets == null ||
            targets.keys.any((target) => target == null) ||
            targets.values.any((row) => row.page != group)) {
          fields.reject('unreadable shown rows');
        }
        if (targets != null && targets.keys.any(rows.containsKey)) {
          fields.reject('a shown row stored in two page groups');
        }
        return () {
          if (digests != null) content[group] = digests;
          if (isDebt(pageOwed!)) pageReads[group] = pageOwed;
          rows.addAll({
            for (final MapEntry(:key, :value) in targets!.entries) key!: value,
          });
        };
      }),
    );
    switch (reading) {
      case CloudRowRead():
        break;
      case CloudRowUnreadable(:final problem):
        return ShownUnreadable(group, problem);
    }
  }
  return ShownRead(
    Shown(
      strategy: strategy,
      pages: pages,
      settings: settings,
      content: content,
      rows: rows,
      highest: highest,
      list: list,
      pageReads: pageReads,
    ),
  );
}

Map<String, ShownRow>? _shownRows(Object? raw) {
  if (raw is! List<Object?>) return null;
  final found = <String, ShownRow>{};
  for (final each in raw) {
    final row = _shownRowFrom(each);
    if (row == null || found.containsKey(row.$1)) return null;
    found[row.$1] = row.$2;
  }
  return found;
}

Map<Target, Version>? _highest(Object? raw) {
  if (raw is! List<Object?>) return null;
  final found = <Target, Version>{};
  for (final each in raw) {
    if (each case [
      final Object? key,
      final num revision,
    ] when isSafeWhole(revision)) {
      final target = _target(key);
      if (target == null || found.containsKey(target)) return null;
      found[target] = Version(revision.toInt());
    } else {
      return null;
    }
  }
  return found;
}
