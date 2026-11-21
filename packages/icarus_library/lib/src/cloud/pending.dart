import 'package:collection/collection.dart';

import '../json.dart';
import '../ops.dart';
import '../outcome.dart';

const retriesBeforePause = 8;

const serverRemembersAnswersFor = Duration(days: 30);

const _setEquality = SetEquality<Object?>();
const _mapEquality = MapEquality<Object?, Object?>();
const _listEquality = ListEquality<Object?>();

sealed class QueueEntry {
  const QueueEntry({required this.place});

  final int place;

  String get id;
}

final class PendingOp extends QueueEntry {
  const PendingOp({
    required super.place,
    required this.work,
    required this.scope,
    required this.authored,
    required this.policy,
    required this.answer,
    required this.retriedAfter,
    this.memory = const Remembered(),
  });

  final Work work;
  final Scope scope;
  final Authored authored;
  final SendPolicy policy;
  final ServerAnswer answer;
  final int retriedAfter;
  final ServerMemory memory;

  StrategyOp get op => work.op;

  String get opId => work.op.opId;

  @override
  String get id => work.op.opId;

  PendingOp copyWith({
    Work? work,
    Authored? authored,
    SendPolicy? policy,
    ServerAnswer? answer,
    int? retriedAfter,
    ServerMemory? memory,
  }) => PendingOp(
    place: place,
    work: work ?? this.work,
    scope: scope,
    authored: authored ?? this.authored,
    policy: policy ?? this.policy,
    answer: answer ?? this.answer,
    retriedAfter: retriedAfter ?? this.retriedAfter,
    memory: memory ?? this.memory,
  );

  @override
  bool operator ==(Object other) =>
      other is PendingOp &&
      other.place == place &&
      other.work == work &&
      other.scope == scope &&
      other.authored == authored &&
      other.policy == policy &&
      other.answer == answer &&
      other.retriedAfter == retriedAfter &&
      other.memory == memory;

  @override
  int get hashCode => Object.hash(
    place,
    work,
    scope,
    authored,
    policy,
    answer,
    retriedAfter,
    memory,
  );

  @override
  String toString() => 'PendingOp($opId, $answer)';
}

final class RetiredOp extends QueueEntry {
  RetiredOp({
    required super.place,
    required this.opId,
    required this.clientId,
    required this.landing,
    required Object? stored,
  }) : stored = jsonValue(stored);

  final String opId;
  final String clientId;
  final Landing landing;
  final Object? stored;

  @override
  String get id => opId;

  @override
  bool operator ==(Object other) =>
      other is RetiredOp &&
      other.place == place &&
      other.opId == opId &&
      other.clientId == clientId &&
      other.landing == landing &&
      sameJson(other.stored, stored);

  @override
  int get hashCode => Object.hash(place, opId, clientId, landing);

  @override
  String toString() => 'RetiredOp($opId)';
}

sealed class ServerMemory {
  const ServerMemory();
}

final class Remembered extends ServerMemory {
  const Remembered();

  @override
  bool operator ==(Object other) => other is Remembered;

  @override
  int get hashCode => (Remembered).hashCode;
}

final class Forgotten extends ServerMemory {
  const Forgotten({required this.afterRead});

  final int afterRead;

  @override
  bool operator ==(Object other) =>
      other is Forgotten && other.afterRead == afterRead;

  @override
  int get hashCode => Object.hash(Forgotten, afterRead);
}

enum Landing { notLanded, mayHaveLanded }

sealed class Work {
  const Work();

  StrategyOp get op;
}

final class OpWork extends Work {
  const OpWork(this.op);

  @override
  final StrategyOp op;

  @override
  bool operator ==(Object other) => other is OpWork && other.op == op;

  @override
  int get hashCode => Object.hash(OpWork, op);
}

final class CheckedDelete extends Work {
  const CheckedDelete(this.op, this.seen);

  @override
  final PageDeleteOp op;
  final SeenPage seen;

  @override
  bool operator ==(Object other) =>
      other is CheckedDelete && other.op == op && other.seen == seen;

  @override
  int get hashCode => Object.hash(CheckedDelete, op, seen);
}

final class SeenPage {
  SeenPage({
    required this.pageDigest,
    required this.pageRevision,
    required this.content,
  });

  final String pageDigest;
  final int pageRevision;
  final SeenContent content;

  @override
  bool operator ==(Object other) =>
      other is SeenPage &&
      other.pageDigest == pageDigest &&
      other.pageRevision == pageRevision &&
      other.content == content;

  @override
  int get hashCode => Object.hash(pageDigest, pageRevision, content);
}

sealed class SeenContent {
  const SeenContent();
}

final class ContentSeen extends SeenContent {
  ContentSeen(Map<SeenPart, String> digests)
    : digests = Map.unmodifiable(digests);

  final Map<SeenPart, String> digests;

  @override
  bool operator ==(Object other) =>
      other is ContentSeen && _mapEquality.equals(other.digests, digests);

  @override
  int get hashCode => _mapEquality.hash(digests);
}

final class ContentNeverRead extends SeenContent {
  const ContentNeverRead();

  @override
  bool operator ==(Object other) => other is ContentNeverRead;

  @override
  int get hashCode => (ContentNeverRead).hashCode;
}

sealed class SeenPart {
  const SeenPart();
}

final class SeenSettings extends SeenPart {
  const SeenSettings();

  @override
  bool operator ==(Object other) => other is SeenSettings;

  @override
  int get hashCode => (SeenSettings).hashCode;

  @override
  String toString() => 'settings';
}

final class SeenElement extends SeenPart {
  const SeenElement(this.id);

  final String id;

  @override
  bool operator ==(Object other) => other is SeenElement && other.id == id;

  @override
  int get hashCode => Object.hash(SeenElement, id);

  @override
  String toString() => 'element:$id';
}

final class SeenLineupGroup extends SeenPart {
  const SeenLineupGroup(this.id);

  final String id;

  @override
  bool operator ==(Object other) => other is SeenLineupGroup && other.id == id;

  @override
  int get hashCode => Object.hash(SeenLineupGroup, id);

  @override
  String toString() => 'lineup:$id';
}

sealed class Scope {
  const Scope();
}

final class StrategyWide extends Scope {
  const StrategyWide();

  @override
  bool operator ==(Object other) => other is StrategyWide;

  @override
  int get hashCode => (StrategyWide).hashCode;
}

final class OnPage extends Scope {
  const OnPage(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is OnPage && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(OnPage, pagePublicId);
}

final class Moving extends Scope {
  const Moving({required this.from, required this.to});

  final String from;
  final String to;

  @override
  bool operator ==(Object other) =>
      other is Moving && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(Moving, from, to);
}

sealed class Authored {
  const Authored();
}

final class AuthoredRow extends Authored {
  const AuthoredRow({
    required this.revision,
    required this.digest,
    this.payloadVersion,
  });

  final int revision;
  final String digest;
  final int? payloadVersion;

  @override
  bool operator ==(Object other) =>
      other is AuthoredRow &&
      other.revision == revision &&
      other.digest == digest &&
      other.payloadVersion == payloadVersion;

  @override
  int get hashCode =>
      Object.hash(AuthoredRow, revision, digest, payloadVersion);

  @override
  String toString() => 'AuthoredRow($revision, $digest)';
}

final class AuthoredUnreadable extends Authored {
  const AuthoredUnreadable();

  @override
  bool operator ==(Object other) => other is AuthoredUnreadable;

  @override
  int get hashCode => (AuthoredUnreadable).hashCode;

  @override
  String toString() => 'AuthoredUnreadable';
}

final class AuthoredNoRow extends Authored {
  const AuthoredNoRow();

  @override
  bool operator ==(Object other) => other is AuthoredNoRow;

  @override
  int get hashCode => (AuthoredNoRow).hashCode;

  @override
  String toString() => 'AuthoredNoRow';
}

enum SendPolicy { live, checked }

sealed class ServerAnswer {
  const ServerAnswer();
}

final class NotAnswered extends ServerAnswer {
  const NotAnswered();

  @override
  bool operator ==(Object other) => other is NotAnswered;

  @override
  int get hashCode => (NotAnswered).hashCode;

  @override
  String toString() => 'NotAnswered';
}

final class AnsweredApplied extends ServerAnswer {
  const AnsweredApplied(this.revision, this.by, {required this.afterRead});

  final int revision;
  final AppliedBy by;
  final int afterRead;

  @override
  bool operator ==(Object other) =>
      other is AnsweredApplied &&
      other.revision == revision &&
      other.by == by &&
      other.afterRead == afterRead;

  @override
  int get hashCode => Object.hash(AnsweredApplied, revision, by, afterRead);

  @override
  String toString() => 'AnsweredApplied($revision, ${by.name})';
}

enum AppliedBy { thisClient, alreadyThere }

final class AnsweredNothingToDo extends ServerAnswer {
  const AnsweredNothingToDo();

  @override
  bool operator ==(Object other) => other is AnsweredNothingToDo;

  @override
  int get hashCode => (AnsweredNothingToDo).hashCode;

  @override
  String toString() => 'AnsweredNothingToDo';
}

final class AnsweredRefused extends ServerAnswer {
  const AnsweredRefused(this.refusal, {required this.afterRead});

  final ServerRefusal refusal;
  final int afterRead;

  @override
  bool operator ==(Object other) =>
      other is AnsweredRefused &&
      other.refusal == refusal &&
      other.afterRead == afterRead;

  @override
  int get hashCode => Object.hash(AnsweredRefused, refusal, afterRead);

  @override
  String toString() => 'AnsweredRefused($refusal)';
}

sealed class ServerRefusal {
  const ServerRefusal();
}

final class RejectedByServer extends ServerRefusal {
  const RejectedByServer(this.reason, this.current);

  final RejectionReason reason;
  final ServerCopy current;

  @override
  bool operator ==(Object other) =>
      other is RejectedByServer &&
      other.reason == reason &&
      other.current == current;

  @override
  int get hashCode => Object.hash(RejectedByServer, reason, current);

  @override
  String toString() => 'RejectedByServer(${reason.wireName})';
}

final class FailedOnServer extends ServerRefusal {
  const FailedOnServer(this.code, this.message);

  final ServerFailure code;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is FailedOnServer && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(FailedOnServer, code, message);

  @override
  String toString() => 'FailedOnServer($code)';
}

sealed class ServerFailure {
  const ServerFailure();
}

final class KnownFailure extends ServerFailure {
  const KnownFailure(this.code);

  final FailureCode code;

  @override
  bool operator ==(Object other) => other is KnownFailure && other.code == code;

  @override
  int get hashCode => Object.hash(KnownFailure, code);

  @override
  String toString() => code.wireName;
}

final class OtherFailure extends ServerFailure {
  const OtherFailure(this.code);

  final String code;

  @override
  bool operator ==(Object other) => other is OtherFailure && other.code == code;

  @override
  int get hashCode => Object.hash(OtherFailure, code);

  @override
  String toString() => code;
}

sealed class ServerCopy {
  const ServerCopy();
}

final class NoServerCopy extends ServerCopy {
  const NoServerCopy();

  @override
  bool operator ==(Object other) => other is NoServerCopy;

  @override
  int get hashCode => (NoServerCopy).hashCode;
}

final class ServerSnapshot extends ServerCopy {
  ServerSnapshot({
    required this.target,
    required this.revision,
    required Map<String, Object?> value,
  }) : value = jsonObject(value);

  final SnapshotTarget target;
  final int revision;
  final JsonObject value;

  @override
  bool operator ==(Object other) =>
      other is ServerSnapshot &&
      other.target == target &&
      other.revision == revision &&
      sameJson(other.value, value);

  @override
  int get hashCode => Object.hash(ServerSnapshot, target, revision);
}

enum SnapshotTarget { strategy, page, pageContent, element, lineup }

final class AttemptFact {
  AttemptFact({
    required this.number,
    required this.clientId,
    required this.build,
    required this.at,
    required this.afterRead,
    required List<StrategyOp> ops,
    required this.outcome,
  }) : ops = List.unmodifiable(ops);

  final int number;
  final String clientId;
  final String build;
  final DateTime at;
  final int afterRead;
  final List<StrategyOp> ops;
  final AttemptOutcome outcome;

  List<String> get opIds => [for (final op in ops) op.opId];

  AttemptFact withOutcome(AttemptOutcome outcome) => AttemptFact(
    number: number,
    clientId: clientId,
    build: build,
    at: at,
    afterRead: afterRead,
    ops: ops,
    outcome: outcome,
  );

  @override
  bool operator ==(Object other) =>
      other is AttemptFact &&
      other.number == number &&
      other.clientId == clientId &&
      other.build == build &&
      other.at == at &&
      other.afterRead == afterRead &&
      _listEquality.equals(other.ops, ops) &&
      other.outcome == outcome;

  @override
  int get hashCode => Object.hash(number, clientId, build, at, outcome);

  @override
  String toString() => 'Attempt($number, $opIds, $outcome)';
}

sealed class AttemptOutcome {
  const AttemptOutcome();
}

final class AttemptOpen extends AttemptOutcome {
  const AttemptOpen();

  @override
  bool operator ==(Object other) => other is AttemptOpen;

  @override
  int get hashCode => (AttemptOpen).hashCode;

  @override
  String toString() => 'open';
}

final class AttemptReleased extends AttemptOutcome {
  const AttemptReleased();

  @override
  bool operator ==(Object other) => other is AttemptReleased;

  @override
  int get hashCode => (AttemptReleased).hashCode;

  @override
  String toString() => 'released';
}

final class AttemptFailed extends AttemptOutcome {
  const AttemptFailed(this.cause, this.at);

  final SendCut cause;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is AttemptFailed && other.cause == cause && other.at == at;

  @override
  int get hashCode => Object.hash(AttemptFailed, cause, at);

  @override
  String toString() => 'failed($cause)';
}

final class AttemptRefusedWhole extends AttemptOutcome {
  const AttemptRefusedWhole(this.refusal);

  final BatchRefusal refusal;

  @override
  bool operator ==(Object other) =>
      other is AttemptRefusedWhole && other.refusal == refusal;

  @override
  int get hashCode => Object.hash(AttemptRefusedWhole, refusal);

  @override
  String toString() => 'refused(${refusal.name})';
}

enum BatchRefusal {
  upgradeRequired,
  unauthenticated,
  editAccessRemoved,
  strategyDeleted,
}

sealed class SendCut {
  const SendCut();
}

final class TransportCut extends SendCut {
  const TransportCut(this.failure);

  final TransportFailure failure;

  @override
  bool operator ==(Object other) =>
      other is TransportCut && other.failure == failure;

  @override
  int get hashCode => Object.hash(TransportCut, failure);

  @override
  String toString() => failure.name;
}

final class AppClosedWhileSending extends SendCut {
  const AppClosedWhileSending();

  @override
  bool operator ==(Object other) => other is AppClosedWhileSending;

  @override
  int get hashCode => (AppClosedWhileSending).hashCode;

  @override
  String toString() => 'app closed';
}

enum TransportFailure { network, timeout, malformedAnswer, missingAnswer }

enum Life { live, gone }

final class StrategyFacts {
  const StrategyFacts({
    required this.presence,
    required this.accessLostAt,
    required this.accessConfirmedAt,
    required this.upgradeTold,
  });

  static const fresh = StrategyFacts(
    presence: Presence.present,
    accessLostAt: 0,
    accessConfirmedAt: 0,
    upgradeTold: NoUpgradeTold(),
  );

  final Presence presence;
  final int accessLostAt;
  final int accessConfirmedAt;
  final UpgradeTold upgradeTold;

  StrategyFacts copyWith({
    Presence? presence,
    int? accessLostAt,
    int? accessConfirmedAt,
    UpgradeTold? upgradeTold,
  }) => StrategyFacts(
    presence: presence ?? this.presence,
    accessLostAt: accessLostAt ?? this.accessLostAt,
    accessConfirmedAt: accessConfirmedAt ?? this.accessConfirmedAt,
    upgradeTold: upgradeTold ?? this.upgradeTold,
  );

  @override
  bool operator ==(Object other) =>
      other is StrategyFacts &&
      other.presence == presence &&
      other.accessLostAt == accessLostAt &&
      other.accessConfirmedAt == accessConfirmedAt &&
      other.upgradeTold == upgradeTold;

  @override
  int get hashCode =>
      Object.hash(presence, accessLostAt, accessConfirmedAt, upgradeTold);
}

enum Presence { present, gone }

sealed class UpgradeTold {
  const UpgradeTold();
}

final class NoUpgradeTold extends UpgradeTold {
  const NoUpgradeTold();

  @override
  bool operator ==(Object other) => other is NoUpgradeTold;

  @override
  int get hashCode => (NoUpgradeTold).hashCode;
}

final class UpgradeToldTo extends UpgradeTold {
  const UpgradeToldTo(this.build, {required this.attempt});

  final String build;
  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is UpgradeToldTo &&
      other.build == build &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(UpgradeToldTo, build, attempt);
}

bool sameSet(Set<Object?> a, Set<Object?> b) => _setEquality.equals(a, b);

bool sameMap(Map<Object?, Object?> a, Map<Object?, Object?> b) =>
    _mapEquality.equals(a, b);

int hashMap(Map<Object?, Object?> map) => _mapEquality.hash(map);

int hashSet(Set<Object?> set) => _setEquality.hash(set);

DateTime retryTimeAfter(DateTime failedAt, int failures) {
  final wait = 300 * (1 << failures.clamp(0, 6));
  final at = failedAt.millisecondsSinceEpoch + wait;
  return DateTime.fromMillisecondsSinceEpoch(
    at > _latestMillis ? _latestMillis : at,
    isUtc: true,
  );
}

const _latestMillis = 8640000000000000;
