import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import '../wire.dart';
import 'events.dart';
import 'pending.dart';

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

DateTime _time(Object? raw) => switch (raw) {
  final num value when isSafeWhole(value) =>
    DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true),
  _ => throw const FormatException('expected a time'),
};

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
      AuthoredRow(:final revision, :final digest, :final payloadVersion) => {
        'revision': revision,
        'digest': digest,
        'payloadVersion': ?payloadVersion,
      },
      AuthoredNoRow() => {'noRow': true},
      AuthoredUnreadable() => {'unreadable': true},
    },
    'policy': entry.policy.name,
    'retriedAfter': entry.retriedAfter,
    'work': switch (entry.work) {
      OpWork() => 'op',
      CheckedDelete(:final seen) => {'checkedDelete': _seenToJson(seen)},
    },
    'answer': _answerToJson(entry.answer),
    if (entry.memory case Forgotten(:final afterRead))
      'forgottenAfterRead': afterRead,
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

Object? _answerToJson(ServerAnswer answer) => switch (answer) {
  NotAnswered() => null,
  AnsweredApplied(:final revision, :final by, :final afterRead) => {
    'applied': revision,
    'by': by.name,
    'afterRead': afterRead,
  },
  AnsweredNothingToDo() => {'nothingToDo': true},
  AnsweredRefused(
    refusal: RejectedByServer(:final reason, :final current),
    :final afterRead,
  ) =>
    {
      'rejected': reason.wireName,
      'afterRead': afterRead,
      if (current case ServerSnapshot(
        :final target,
        :final revision,
        :final value,
      ))
        'current': {
          'target': target.name,
          'revision': revision,
          'value': value.toJson(),
        },
    },
  AnsweredRefused(
    refusal: FailedOnServer(:final code, :final message),
    :final afterRead,
  ) =>
    {'failed': '$code', 'message': message, 'afterRead': afterRead},
};

Decoded<QueueEntry> decodeEntry(int place, Object? json) => JsonFields.read(
  json,
  'pending entry',
  (fields) {
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
        final policy = _named(fields, 'policy', SendPolicy.values);
        final retriedAfter = fields.whole('retriedAfter');
        if (retriedAfter < 0) fields.reject('a negative attempt number');
        final answer = fields.has('answer')
            ? fields.decoded('answer', _answer)
            : const NotAnswered();
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
        if (op != null && scope != null && !_scopeFits(op, scope)) {
          fields.reject('a scope or field base that does not fit its op');
        }
        final forgotten = fields.optionalWhole('forgottenAfterRead');
        if (forgotten != null && forgotten < 0) {
          fields.reject('a negative read number');
        }
        return () => PendingOp(
          place: place,
          work: work!,
          scope: scope!,
          authored: authored!,
          policy: policy!,
          answer: answer!,
          retriedAfter: retriedAfter,
          memory: forgotten == null
              ? const Remembered()
              : Forgotten(afterRead: forgotten),
        );
      default:
        fields.reject('an entry kind this build does not read');
        return () => throw StateError('rejected');
    }
  },
);

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
      if (fields.json['noRow'] == true) return () => const AuthoredNoRow();
      if (fields.json['unreadable'] == true) {
        return () => const AuthoredUnreadable();
      }
      final revision = fields.whole('revision');
      final digest = fields.string('digest');
      final payloadVersion = fields.has('payloadVersion')
          ? fields.whole('payloadVersion')
          : null;
      return () => AuthoredRow(
        revision: revision,
        digest: digest,
        payloadVersion: payloadVersion,
      );
    });

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

Decoded<ServerAnswer> _answer(Object? json) =>
    JsonFields.read(json, 'answer', (fields) {
      if (fields.json['nothingToDo'] == true) {
        return () => const AnsweredNothingToDo();
      }
      final afterRead = fields.whole('afterRead');
      if (afterRead < 0) fields.reject('a negative read number');
      if (fields.has('applied')) {
        final revision = fields.whole('applied');
        final by = _named(fields, 'by', AppliedBy.values);
        return () => AnsweredApplied(revision, by!, afterRead: afterRead);
      }
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
          }
              when isSafeWhole(revision) &&
                  SnapshotTarget.values.asNameMap().containsKey(target) =>
            ServerSnapshot(
              target: SnapshotTarget.values.asNameMap()[target]!,
              revision: revision.toInt(),
              value: value,
            ),
          null => const NoServerCopy(),
          _ => () {
            fields.reject('an unreadable server copy');
            return const NoServerCopy();
          }(),
        };
        return () => AnsweredRefused(
          RejectedByServer(reason!, current),
          afterRead: afterRead,
        );
      }
      final code = fields.string('failed');
      final message = fields.string('message');
      return () => AnsweredRefused(
        FailedOnServer(switch (FailureCode.values
            .where((known) => known.wireName == code)
            .firstOrNull) {
          final known? => KnownFailure(known),
          null => OtherFailure(code),
        }, message),
        afterRead: afterRead,
      );
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
    final reading = _fromText(text, (json) => decodeEntry(place, json));
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
  'afterRead': attempt.afterRead,
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
    AttemptRefusedWhole(:final refusal) => {'refused': refusal.name},
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
  {'failed': 'appClosed', 'at': final num at} when isSafeWhole(at) =>
    AttemptFailed(const AppClosedWhileSending(), _time(at)),
  {'failed': final String name, 'at': final num at}
      when isSafeWhole(at) &&
          TransportFailure.values.asNameMap().containsKey(name) =>
    AttemptFailed(
      TransportCut(TransportFailure.values.asNameMap()[name]!),
      _time(at),
    ),
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
        final at = fields.time('at');
        final afterRead = fields.whole('afterRead');
        if (afterRead < 0) fields.reject('a negative read number');
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
          afterRead: afterRead,
          ops: ops,
          outcome: outcome!,
        );
      }),
    );

Map<String, Object?> factsToJson(StrategyFacts facts) => {
  'version': cloudRowVersion,
  'presence': facts.presence.name,
  'accessLostAt': facts.accessLostAt,
  'accessConfirmedAt': facts.accessConfirmedAt,
  if (facts.upgradeTold case UpgradeToldTo(:final build, :final attempt))
    'upgradeTold': {'build': build, 'attempt': attempt},
};

CloudRowReading<StrategyFacts> factsFromText(String text) => _fromText(
  text,
  (json) => JsonFields.read(json, 'cloud facts', (fields) {
    _versioned(fields, 'cloud facts');
    final presence = _named(fields, 'presence', Presence.values);
    final lost = fields.whole('accessLostAt');
    final confirmed = fields.whole('accessConfirmedAt');
    if (lost < 0 || confirmed < 0) fields.reject('a negative attempt number');
    final UpgradeTold upgrade = switch (fields.json['upgradeTold']) {
      null => const NoUpgradeTold(),
      {'build': final String build, 'attempt': final num attempt}
          when isSafeWhole(attempt) && attempt >= 1 =>
        UpgradeToldTo(build, attempt: attempt.toInt()),
      _ => () {
        fields.reject('an unreadable upgrade request');
        return const NoUpgradeTold();
      }(),
    };
    return () => StrategyFacts(
      presence: presence!,
      accessLostAt: lost,
      accessConfirmedAt: confirmed,
      upgradeTold: upgrade,
    );
  }),
);

final class Counters {
  const Counters({required this.nextAttempt, required this.nextRead});

  final int nextAttempt;
  final int nextRead;

  @override
  bool operator ==(Object other) =>
      other is Counters &&
      other.nextAttempt == nextAttempt &&
      other.nextRead == nextRead;

  @override
  int get hashCode => Object.hash(nextAttempt, nextRead);
}

Map<String, Object?> countersToJson(Counters counters) => {
  'version': cloudRowVersion,
  'nextAttempt': counters.nextAttempt,
  'nextRead': counters.nextRead,
};

CloudRowReading<Counters> countersFromText(String text) => _fromText(
  text,
  (json) => JsonFields.read(json, 'counters', (fields) {
    _versioned(fields, 'counters');
    final nextAttempt = fields.whole('nextAttempt');
    final nextRead = fields.whole('nextRead');
    if (nextAttempt < 1 || nextRead < 1) {
      fields.reject('counters start at 1');
    }
    return () => Counters(nextAttempt: nextAttempt, nextRead: nextRead);
  }),
);
