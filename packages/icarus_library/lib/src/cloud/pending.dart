import 'package:collection/collection.dart';

import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import '../rows.dart';

const retriesBeforePause = 8;

const serverRemembersAnswersFor = Duration(days: 30);

const resendWindow = Duration(days: 29);

const liveFor = Duration(seconds: 20);

final class ServerTimeBasis {
  const ServerTimeBasis(this.serverTime, {required this.heldAt});

  final int serverTime;
  final Duration heldAt;

  @override
  bool operator ==(Object other) =>
      other is ServerTimeBasis &&
      other.serverTime == serverTime &&
      other.heldAt == heldAt;

  @override
  int get hashCode => Object.hash(ServerTimeBasis, serverTime, heldAt);

  @override
  String toString() => 'ServerTimeBasis($serverTime, held at $heldAt)';
}

const sendGiveUpAfter = Duration(hours: 1);

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
    required this.authoredIn,
    required this.authoredAt,
    required this.refusal,
    required this.retriedAfter,
    this.window = const WindowOpen(),
    this.behindOwn = false,
    this.basis,
  });

  final Work work;
  final Scope scope;
  final Authored authored;
  final int authoredIn;
  final DateTime authoredAt;
  final RefusalRecord refusal;
  final int retriedAfter;
  final ResendWindow window;
  final bool behindOwn;
  final ServerTimeBasis? basis;

  StrategyOp get op => work.op;

  String get opId => work.op.opId;

  @override
  String get id => work.op.opId;

  PendingOp copyWith({
    Work? work,
    Authored? authored,
    RefusalRecord? refusal,
    int? retriedAfter,
    ResendWindow? window,
    bool dropBasis = false,
  }) => PendingOp(
    place: place,
    work: work ?? this.work,
    scope: scope,
    authored: authored ?? this.authored,
    authoredIn: authoredIn,
    authoredAt: authoredAt,
    refusal: refusal ?? this.refusal,
    retriedAfter: retriedAfter ?? this.retriedAfter,
    window: window ?? this.window,
    behindOwn: behindOwn,
    basis: dropBasis ? null : basis,
  );

  @override
  bool operator ==(Object other) =>
      other is PendingOp &&
      other.place == place &&
      other.work == work &&
      other.scope == scope &&
      other.authored == authored &&
      other.authoredIn == authoredIn &&
      other.authoredAt == authoredAt &&
      other.refusal == refusal &&
      other.retriedAfter == retriedAfter &&
      other.window == window &&
      other.behindOwn == behindOwn &&
      other.basis == basis;

  @override
  int get hashCode => Object.hash(
    place,
    work,
    scope,
    authored,
    authoredIn,
    refusal,
    retriedAfter,
    window,
    behindOwn,
  );

  @override
  String toString() => 'PendingOp($opId, $refusal)';
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

sealed class ResendWindow {
  const ResendWindow();
}

final class WindowOpen extends ResendWindow {
  const WindowOpen();

  @override
  bool operator ==(Object other) => other is WindowOpen;

  @override
  int get hashCode => (WindowOpen).hashCode;
}

final class WindowPassed extends ResendWindow {
  const WindowPassed();

  @override
  bool operator ==(Object other) => other is WindowPassed;

  @override
  int get hashCode => (WindowPassed).hashCode;
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

final class ProducedRow {
  const ProducedRow({
    required this.page,
    required this.revision,
    required this.digest,
    this.justifies = true,
  });

  final String? page;
  final int revision;
  final String digest;
  final bool justifies;

  ProducedRow unjustified() => ProducedRow(
    page: page,
    revision: revision,
    digest: digest,
    justifies: false,
  );

  @override
  bool operator ==(Object other) =>
      other is ProducedRow &&
      other.page == page &&
      other.revision == revision &&
      other.digest == digest &&
      other.justifies == justifies;

  @override
  int get hashCode =>
      Object.hash(ProducedRow, page, revision, digest, justifies);

  @override
  String toString() => 'ProducedRow($page, $revision)';
}

final class AuthoredRow extends Authored {
  const AuthoredRow({
    required this.revision,
    required this.digest,
    this.payloadVersion,
    this.produces,
    this.movedRow,
  });

  final int revision;
  final String digest;
  final int? payloadVersion;
  final ProducedRow? produces;
  final Row? movedRow;

  @override
  bool operator ==(Object other) =>
      other is AuthoredRow &&
      other.revision == revision &&
      other.digest == digest &&
      other.payloadVersion == payloadVersion &&
      other.produces == produces &&
      other.movedRow == movedRow;

  @override
  int get hashCode => Object.hash(
    AuthoredRow,
    revision,
    digest,
    payloadVersion,
    produces,
    movedRow,
  );

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

final class KeptOverServer extends Authored {
  const KeptOverServer(this.revision);

  final int revision;

  @override
  bool operator ==(Object other) =>
      other is KeptOverServer && other.revision == revision;

  @override
  int get hashCode => Object.hash(KeptOverServer, revision);

  @override
  String toString() => 'KeptOverServer($revision)';
}

final class AuthoredNoRow extends Authored {
  const AuthoredNoRow({this.produces});

  final ProducedRow? produces;

  @override
  bool operator ==(Object other) =>
      other is AuthoredNoRow && other.produces == produces;

  @override
  int get hashCode => Object.hash(AuthoredNoRow, produces);

  @override
  String toString() => 'AuthoredNoRow';
}

enum SendPolicy { live, checked }

sealed class RefusalRecord {
  const RefusalRecord();
}

final class NotRefused extends RefusalRecord {
  const NotRefused();

  @override
  bool operator ==(Object other) => other is NotRefused;

  @override
  int get hashCode => (NotRefused).hashCode;

  @override
  String toString() => 'not refused';
}

final class RefusedWith extends RefusalRecord {
  const RefusedWith(this.refusal);

  final ServerRefusal refusal;

  @override
  bool operator ==(Object other) =>
      other is RefusedWith && other.refusal == refusal;

  @override
  int get hashCode => Object.hash(RefusedWith, refusal);

  @override
  String toString() => 'refused: $refusal';
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
    required List<StrategyOp> ops,
    required this.outcome,
  }) : ops = List.unmodifiable(ops);

  final int number;
  final String clientId;
  final String build;
  final DateTime at;
  final List<StrategyOp> ops;
  final AttemptOutcome outcome;

  List<String> get opIds => [for (final op in ops) op.opId];

  AttemptFact withOutcome(AttemptOutcome outcome) => AttemptFact(
    number: number,
    clientId: clientId,
    build: build,
    at: at,
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
  uncheckedTooLate,
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

enum LandedShape { whole, partial }

final class LandedWork {
  const LandedWork({
    required this.attempt,
    required this.position,
    required this.op,
    required this.revision,
    required this.shape,
    required this.own,
    required this.firstSentAt,
    this.produced,
    this.movedRow,
    this.shownWithout = false,
  });

  final int attempt;
  final int position;
  final StrategyOp op;
  final int revision;
  final LandedShape shape;
  final bool own;
  final DateTime firstSentAt;
  final ProducedRow? produced;
  final Row? movedRow;
  final bool shownWithout;

  LandedWork withoutProduced() => LandedWork(
    attempt: attempt,
    position: position,
    op: op,
    revision: revision,
    shape: shape,
    own: own,
    firstSentAt: firstSentAt,
    movedRow: movedRow,
    shownWithout: shownWithout,
  );

  LandedWork seenWithout() => LandedWork(
    attempt: attempt,
    position: position,
    op: op,
    revision: revision,
    shape: shape,
    own: own,
    firstSentAt: firstSentAt,
    produced: produced,
    movedRow: movedRow,
    shownWithout: true,
  );

  @override
  bool operator ==(Object other) =>
      other is LandedWork &&
      other.attempt == attempt &&
      other.position == position &&
      other.op == op &&
      other.revision == revision &&
      other.shape == shape &&
      other.own == own &&
      other.firstSentAt == firstSentAt &&
      other.produced == produced &&
      other.movedRow == movedRow &&
      other.shownWithout == shownWithout;

  @override
  int get hashCode => Object.hash(
    LandedWork,
    attempt,
    position,
    op,
    revision,
    shape,
    own,
    firstSentAt,
    produced,
    shownWithout,
  );

  int compareTo(LandedWork other) {
    final byAttempt = attempt.compareTo(other.attempt);
    return byAttempt != 0 ? byAttempt : position.compareTo(other.position);
  }

  @override
  String toString() =>
      'Landed(${op.opId} at $revision, ${shape.name}${own ? '' : ', not ours'})';
}

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
