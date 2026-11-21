import '../json.dart';
import '../ops.dart';
import '../outcome.dart';

const retriesBeforePause = 8;

const serverRemembersAnswersFor = Duration(days: 30);

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
    required this.against,
    required this.policy,
    required this.wait,
    required this.state,
  });

  final Work work;
  final Scope scope;
  final Against against;
  final SendPolicy policy;
  final BaseWait wait;
  final PendingState state;

  StrategyOp get op => work.op;

  String get opId => work.op.opId;

  @override
  String get id => work.op.opId;

  PendingOp copyWith({
    Work? work,
    Against? against,
    SendPolicy? policy,
    BaseWait? wait,
    PendingState? state,
  }) => PendingOp(
    place: place,
    work: work ?? this.work,
    scope: scope,
    against: against ?? this.against,
    policy: policy ?? this.policy,
    wait: wait ?? this.wait,
    state: state ?? this.state,
  );

  @override
  bool operator ==(Object other) =>
      other is PendingOp &&
      other.place == place &&
      other.work == work &&
      other.scope == scope &&
      other.against == against &&
      other.policy == policy &&
      other.wait == wait &&
      other.state == state;

  @override
  int get hashCode =>
      Object.hash(place, work, scope, against, policy, wait, state);

  @override
  String toString() => 'PendingOp($opId, $state)';
}

final class RetiredOp extends QueueEntry {
  RetiredOp({
    required super.place,
    required this.opId,
    required this.clientId,
    required this.landing,
    required Object? stored,
  }) : stored = frozenJson(stored);

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

final class UnreadableEntry extends QueueEntry {
  const UnreadableEntry({
    required super.place,
    required this.text,
    required this.problem,
  });

  final String text;
  final String problem;

  @override
  String get id => 'unreadable/$place';

  @override
  bool operator ==(Object other) =>
      other is UnreadableEntry &&
      other.place == place &&
      other.text == text &&
      other.problem == problem;

  @override
  int get hashCode => Object.hash(place, text, problem);

  @override
  String toString() => 'UnreadableEntry($place, $problem)';
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

  @override
  String toString() => 'OpWork(${op.opId})';
}

final class CheckedDelete extends Work {
  const CheckedDelete(this.op, this.seen, this.verdict);

  @override
  final PageDeleteOp op;
  final SeenPage seen;
  final DeleteVerdict verdict;

  @override
  bool operator ==(Object other) =>
      other is CheckedDelete &&
      other.op == op &&
      other.seen == seen &&
      other.verdict == verdict;

  @override
  int get hashCode => Object.hash(CheckedDelete, op, seen, verdict);

  @override
  String toString() => 'CheckedDelete(${op.opId}, $verdict)';
}

sealed class DeleteVerdict {
  const DeleteVerdict();
}

final class AwaitingCheck extends DeleteVerdict {
  const AwaitingCheck();

  @override
  bool operator ==(Object other) => other is AwaitingCheck;

  @override
  int get hashCode => (AwaitingCheck).hashCode;

  @override
  String toString() => 'AwaitingCheck';
}

final class HeldForUser extends DeleteVerdict {
  const HeldForUser(this.cause);

  final HeldDeleteCause cause;

  @override
  bool operator ==(Object other) =>
      other is HeldForUser && other.cause == cause;

  @override
  int get hashCode => Object.hash(HeldForUser, cause);

  @override
  String toString() => 'HeldForUser(${cause.name})';
}

enum HeldDeleteCause { pageChanged, contentNeverRead, pageUnreadable }

sealed class Scope {
  const Scope();
}

final class StrategyWide extends Scope {
  const StrategyWide();

  @override
  bool operator ==(Object other) => other is StrategyWide;

  @override
  int get hashCode => (StrategyWide).hashCode;

  @override
  String toString() => 'StrategyWide';
}

final class OnPage extends Scope {
  const OnPage(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is OnPage && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(OnPage, pagePublicId);

  @override
  String toString() => 'OnPage($pagePublicId)';
}

sealed class Against {
  const Against();
}

final class OnBase extends Against {
  const OnBase(this.revision);

  final int? revision;

  @override
  bool operator ==(Object other) =>
      other is OnBase && other.revision == revision;

  @override
  int get hashCode => Object.hash(OnBase, revision);

  @override
  String toString() => 'OnBase($revision)';
}

final class StackedOn extends Against {
  const StackedOn(this.opId, this.revision);

  final String opId;
  final int? revision;

  @override
  bool operator ==(Object other) =>
      other is StackedOn && other.opId == opId && other.revision == revision;

  @override
  int get hashCode => Object.hash(StackedOn, opId, revision);

  @override
  String toString() => 'StackedOn($opId, $revision)';
}

enum SendPolicy { live, checked }

sealed class BaseWait {
  const BaseWait();
}

final class NoWait extends BaseWait {
  const NoWait();

  @override
  bool operator ==(Object other) => other is NoWait;

  @override
  int get hashCode => (NoWait).hashCode;

  @override
  String toString() => 'NoWait';
}

final class UntilBaseShows extends BaseWait {
  const UntilBaseShows(this.revision);

  final int revision;

  @override
  bool operator ==(Object other) =>
      other is UntilBaseShows && other.revision == revision;

  @override
  int get hashCode => Object.hash(UntilBaseShows, revision);

  @override
  String toString() => 'UntilBaseShows($revision)';
}

sealed class PendingState {
  const PendingState();
}

final class Unsent extends PendingState {
  const Unsent(this.delivery, this.go);

  final Unclaimed delivery;
  final Go go;

  @override
  bool operator ==(Object other) =>
      other is Unsent && other.delivery == delivery && other.go == go;

  @override
  int get hashCode => Object.hash(Unsent, delivery, go);

  @override
  String toString() => 'Unsent($delivery, $go)';
}

final class Claimed extends PendingState {
  const Claimed(this.attempt, this.before);

  final Attempt attempt;
  final Unclaimed before;

  @override
  bool operator ==(Object other) =>
      other is Claimed && other.attempt == attempt && other.before == before;

  @override
  int get hashCode => Object.hash(Claimed, attempt, before);

  @override
  String toString() => 'Claimed(${attempt.id}, $before)';
}

final class Accepted extends PendingState {
  const Accepted(this.revision, {this.awaiting = const AwaitingRow()});

  final int revision;
  final AwaitingBase awaiting;

  @override
  bool operator ==(Object other) =>
      other is Accepted &&
      other.revision == revision &&
      other.awaiting == awaiting;

  @override
  int get hashCode => Object.hash(Accepted, revision, awaiting);

  @override
  String toString() => 'Accepted($revision, $awaiting)';
}

sealed class AwaitingBase {
  const AwaitingBase();
}

final class AwaitingRow extends AwaitingBase {
  const AwaitingRow();

  @override
  bool operator ==(Object other) => other is AwaitingRow;

  @override
  int get hashCode => (AwaitingRow).hashCode;

  @override
  String toString() => 'AwaitingRow';
}

final class AwaitingCopy extends AwaitingBase {
  const AwaitingCopy(this.seen);

  final CopySeen seen;

  @override
  bool operator ==(Object other) => other is AwaitingCopy && other.seen == seen;

  @override
  int get hashCode => Object.hash(AwaitingCopy, seen);

  @override
  String toString() => 'AwaitingCopy(${seen.name})';
}

enum CopySeen { neither, strategyOnly }

final class ServerRefused extends PendingState {
  const ServerRefused(this.refusal);

  final ServerRefusal refusal;

  @override
  bool operator ==(Object other) =>
      other is ServerRefused && other.refusal == refusal;

  @override
  int get hashCode => Object.hash(ServerRefused, refusal);

  @override
  String toString() => 'ServerRefused($refusal)';
}

final class Attempt {
  const Attempt(this.id, {required this.clientId, required this.at});

  final String id;
  final String clientId;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is Attempt &&
      other.id == id &&
      other.clientId == clientId &&
      other.at == at;

  @override
  int get hashCode => Object.hash(id, clientId, at);

  @override
  String toString() => 'Attempt($id, $clientId)';
}

sealed class Unclaimed {
  const Unclaimed();
}

final class NeverSent extends Unclaimed {
  const NeverSent();

  @override
  bool operator ==(Object other) => other is NeverSent;

  @override
  int get hashCode => (NeverSent).hashCode;

  @override
  String toString() => 'NeverSent';
}

final class AnswerUnknown extends Unclaimed {
  const AnswerUnknown({
    required this.clientId,
    required this.firstSentAt,
    required this.failures,
    required this.retry,
    required this.cause,
  });

  final String clientId;
  final DateTime firstSentAt;
  final int failures;
  final Backoff retry;
  final SendCut cause;

  AnswerUnknown copyWith({int? failures, Backoff? retry, SendCut? cause}) =>
      AnswerUnknown(
        clientId: clientId,
        firstSentAt: firstSentAt,
        failures: failures ?? this.failures,
        retry: retry ?? this.retry,
        cause: cause ?? this.cause,
      );

  @override
  bool operator ==(Object other) =>
      other is AnswerUnknown &&
      other.clientId == clientId &&
      other.firstSentAt == firstSentAt &&
      other.failures == failures &&
      other.retry == retry &&
      other.cause == cause;

  @override
  int get hashCode =>
      Object.hash(AnswerUnknown, clientId, firstSentAt, failures, retry, cause);

  @override
  String toString() => 'AnswerUnknown($clientId, $failures, $retry, $cause)';
}

sealed class Backoff {
  const Backoff();
}

final class RetryNow extends Backoff {
  const RetryNow();

  @override
  bool operator ==(Object other) => other is RetryNow;

  @override
  int get hashCode => (RetryNow).hashCode;

  @override
  String toString() => 'RetryNow';
}

final class RetryAfter extends Backoff {
  const RetryAfter(this.at);

  final DateTime at;

  @override
  bool operator ==(Object other) => other is RetryAfter && other.at == at;

  @override
  int get hashCode => Object.hash(RetryAfter, at);

  @override
  String toString() => 'RetryAfter(${at.toIso8601String()})';
}

final class RetriesExhausted extends Backoff {
  const RetriesExhausted();

  @override
  bool operator ==(Object other) => other is RetriesExhausted;

  @override
  int get hashCode => (RetriesExhausted).hashCode;

  @override
  String toString() => 'RetriesExhausted';
}

final class ServerForgotAnswer extends Backoff {
  const ServerForgotAnswer();

  @override
  bool operator ==(Object other) => other is ServerForgotAnswer;

  @override
  int get hashCode => (ServerForgotAnswer).hashCode;

  @override
  String toString() => 'ServerForgotAnswer';
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
  String toString() => 'TransportCut(${failure.name})';
}

final class AppClosedWhileSending extends SendCut {
  const AppClosedWhileSending();

  @override
  bool operator ==(Object other) => other is AppClosedWhileSending;

  @override
  int get hashCode => (AppClosedWhileSending).hashCode;

  @override
  String toString() => 'AppClosedWhileSending';
}

enum TransportFailure { network, timeout, malformedAnswer, missingAnswer }

sealed class Go {
  const Go();
}

final class Free extends Go {
  const Free();

  @override
  bool operator ==(Object other) => other is Free;

  @override
  int get hashCode => (Free).hashCode;

  @override
  String toString() => 'Free';
}

final class NeedsUser extends Go {
  const NeedsUser(this.reason);

  final UserReason reason;

  @override
  bool operator ==(Object other) =>
      other is NeedsUser && other.reason == reason;

  @override
  int get hashCode => Object.hash(NeedsUser, reason);

  @override
  String toString() => 'NeedsUser($reason)';
}

sealed class UserReason {
  const UserReason();
}

final class Oversized extends UserReason {
  const Oversized();

  @override
  bool operator ==(Object other) => other is Oversized;

  @override
  int get hashCode => (Oversized).hashCode;

  @override
  String toString() => 'Oversized';
}

final class NoLongerFits extends UserReason {
  const NoLongerFits(this.serverRevision);

  final int serverRevision;

  @override
  bool operator ==(Object other) =>
      other is NoLongerFits && other.serverRevision == serverRevision;

  @override
  int get hashCode => Object.hash(NoLongerFits, serverRevision);

  @override
  String toString() => 'NoLongerFits($serverRevision)';
}

final class IncompletePageCopy extends UserReason {
  const IncompletePageCopy.imported(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is IncompletePageCopy && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(IncompletePageCopy, pagePublicId);

  @override
  String toString() => 'IncompletePageCopy($pagePublicId)';
}

final class OnDeletedPage extends UserReason {
  const OnDeletedPage(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is OnDeletedPage && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(OnDeletedPage, pagePublicId);

  @override
  String toString() => 'OnDeletedPage($pagePublicId)';
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
  String toString() => 'RejectedByServer(${reason.wireName}, $current)';
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

  @override
  String toString() => 'NoServerCopy';
}

final class ServerSnapshot extends ServerCopy {
  ServerSnapshot({
    required this.target,
    required this.revision,
    required Map<String, Object?> value,
  }) : value = frozenJsonObject(value);

  final SnapshotTarget target;
  final int revision;
  final Map<String, Object?> value;

  @override
  bool operator ==(Object other) =>
      other is ServerSnapshot &&
      other.target == target &&
      other.revision == revision &&
      sameJson(other.value, value);

  @override
  int get hashCode => Object.hash(ServerSnapshot, target, revision);

  @override
  String toString() => 'ServerSnapshot(${target.name}, $revision)';
}

enum SnapshotTarget { strategy, page, pageContent, element, lineup }

final class SeenPage {
  const SeenPage({
    required this.name,
    required this.isAttack,
    required this.content,
  });

  final String name;
  final bool isAttack;
  final SeenContent content;

  @override
  bool operator ==(Object other) =>
      other is SeenPage &&
      other.name == name &&
      other.isAttack == isAttack &&
      other.content == content;

  @override
  int get hashCode => Object.hash(name, isAttack, content);

  @override
  String toString() => 'SeenPage($name, $isAttack, $content)';
}

sealed class SeenContent {
  const SeenContent();
}

final class ContentSeen extends SeenContent {
  ContentSeen(Map<SeenPart, int> revisions)
    : revisions = Map.unmodifiable(revisions);

  final Map<SeenPart, int> revisions;

  @override
  bool operator ==(Object other) =>
      other is ContentSeen &&
      other.revisions.length == revisions.length &&
      revisions.entries.every(
        (entry) => other.revisions[entry.key] == entry.value,
      );

  @override
  int get hashCode => Object.hashAllUnordered(
    revisions.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );

  @override
  String toString() => 'ContentSeen($revisions)';
}

final class ContentNeverRead extends SeenContent {
  const ContentNeverRead();

  @override
  bool operator ==(Object other) => other is ContentNeverRead;

  @override
  int get hashCode => (ContentNeverRead).hashCode;

  @override
  String toString() => 'ContentNeverRead';
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

DateTime retryTimeAfter(DateTime failedAt, int failures) {
  final wait = 300 * (1 << failures.clamp(0, 6));
  final at = failedAt.millisecondsSinceEpoch + wait;
  return DateTime.fromMillisecondsSinceEpoch(
    at > _latestMillis ? _latestMillis : at,
    isUtc: true,
  );
}

const _latestMillis = 8640000000000000;
