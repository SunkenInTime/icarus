import 'dart:convert';

import '../json.dart';
import '../ops.dart';
import '../outcome.dart';

const maxCloudOpBytes = 900 * 1024;
const maxCloudArrayEntries = 8000;
const retriesBeforePause = 8;

sealed class QueueEntry {
  const QueueEntry({required this.opId, required this.clientId});

  final String opId;
  final String clientId;
}

final class PendingOp extends QueueEntry {
  PendingOp({
    required this.op,
    required super.clientId,
    required this.check,
    required this.state,
  }) : super(opId: op.opId);

  final StrategyOp op;
  final DeleteCheck check;
  final PendingState state;

  PendingOp copyWith({
    StrategyOp? op,
    DeleteCheck? check,
    PendingState? state,
  }) => PendingOp(
    op: op ?? this.op,
    clientId: clientId,
    check: check ?? this.check,
    state: state ?? this.state,
  );

  @override
  bool operator ==(Object other) =>
      other is PendingOp &&
      other.op == op &&
      other.clientId == clientId &&
      other.check == check &&
      other.state == state;

  @override
  int get hashCode => Object.hash(op, clientId, check, state);

  @override
  String toString() => 'PendingOp($opId, $state)';
}

final class RetiredOp extends QueueEntry {
  RetiredOp({
    required super.opId,
    required super.clientId,
    required this.stored,
  });

  final Object? stored;

  @override
  bool operator ==(Object other) =>
      other is RetiredOp &&
      other.opId == opId &&
      other.clientId == clientId &&
      sameJson(other.stored, stored);

  @override
  int get hashCode => Object.hash(opId, clientId);

  @override
  String toString() => 'RetiredOp($opId)';
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
  const Claimed(this.before);

  final Unclaimed before;

  @override
  bool operator ==(Object other) => other is Claimed && other.before == before;

  @override
  int get hashCode => Object.hash(Claimed, before);

  @override
  String toString() => 'Claimed($before)';
}

final class Accepted extends PendingState {
  const Accepted(this.revision);

  final int revision;

  @override
  bool operator ==(Object other) =>
      other is Accepted && other.revision == revision;

  @override
  int get hashCode => Object.hash(Accepted, revision);

  @override
  String toString() => 'Accepted($revision)';
}

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
    required this.failures,
    required this.retryAt,
    required this.cause,
  });

  final int failures;
  final RetryAt retryAt;
  final SendCut cause;

  @override
  bool operator ==(Object other) =>
      other is AnswerUnknown &&
      other.failures == failures &&
      other.retryAt == retryAt &&
      other.cause == cause;

  @override
  int get hashCode => Object.hash(AnswerUnknown, failures, retryAt, cause);

  @override
  String toString() => 'AnswerUnknown($failures, $retryAt, $cause)';
}

sealed class RetryAt {
  const RetryAt();
}

final class RetryNow extends RetryAt {
  const RetryNow();

  @override
  bool operator ==(Object other) => other is RetryNow;

  @override
  int get hashCode => (RetryNow).hashCode;

  @override
  String toString() => 'RetryNow';
}

final class RetryAfter extends RetryAt {
  const RetryAfter(this.at);

  final DateTime at;

  @override
  bool operator ==(Object other) => other is RetryAfter && other.at == at;

  @override
  int get hashCode => Object.hash(RetryAfter, at);

  @override
  String toString() => 'RetryAfter(${at.toIso8601String()})';
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

final class Paused extends Go {
  const Paused(this.reason);

  final PauseReason reason;

  @override
  bool operator ==(Object other) => other is Paused && other.reason == reason;

  @override
  int get hashCode => Object.hash(Paused, reason);

  @override
  String toString() => 'Paused(${reason.name})';
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

enum PauseReason { retriesExhausted, editAccessRemoved, upgradeRequired }

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
  const IncompletePageCopy(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is IncompletePageCopy && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(IncompletePageCopy, pagePublicId);

  @override
  String toString() => 'IncompletePageCopy($pagePublicId)';
}

final class HeldPageDelete extends UserReason {
  const HeldPageDelete(this.cause);

  final HeldDeleteCause cause;

  @override
  bool operator ==(Object other) =>
      other is HeldPageDelete && other.cause == cause;

  @override
  int get hashCode => Object.hash(HeldPageDelete, cause);

  @override
  String toString() => 'HeldPageDelete(${cause.name})';
}

enum HeldDeleteCause { pageChanged, contentNeverRead, pageUnreadable }

final class StrategyDeleted extends UserReason {
  const StrategyDeleted();

  @override
  bool operator ==(Object other) => other is StrategyDeleted;

  @override
  int get hashCode => (StrategyDeleted).hashCode;

  @override
  String toString() => 'StrategyDeleted';
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

sealed class DeleteCheck {
  const DeleteCheck();
}

final class NoCheck extends DeleteCheck {
  const NoCheck();

  @override
  bool operator ==(Object other) => other is NoCheck;

  @override
  int get hashCode => (NoCheck).hashCode;

  @override
  String toString() => 'NoCheck';
}

final class CheckAgainst extends DeleteCheck {
  const CheckAgainst(this.seen);

  final SeenPage seen;

  @override
  bool operator ==(Object other) => other is CheckAgainst && other.seen == seen;

  @override
  int get hashCode => Object.hash(CheckAgainst, seen);

  @override
  String toString() => 'CheckAgainst($seen)';
}

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

sealed class CloudSize {
  const CloudSize();
}

final class WithinPolicy extends CloudSize {
  const WithinPolicy();
}

final class OverPolicy extends CloudSize {
  const OverPolicy();
}

CloudSize cloudSizeOf(StrategyOp op) {
  final json = op.toJson();
  return utf8.encode(jsonEncode(json)).length > maxCloudOpBytes ||
          _tooManyEntries(json)
      ? const OverPolicy()
      : const WithinPolicy();
}

bool _tooManyEntries(Object? value) => switch (value) {
  final List<Object?> list =>
    list.length > maxCloudArrayEntries || list.any(_tooManyEntries),
  final Map<String, Object?> map => map.values.any(_tooManyEntries),
  _ => false,
};

DateTime retryTimeAfter(DateTime failedAt, int failures) =>
    failedAt.add(Duration(milliseconds: 300 * (1 << failures.clamp(0, 6))));
