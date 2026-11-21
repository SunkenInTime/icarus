import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

const clientId = 'client-1';

final now = DateTime.utc(2026, 11, 20, 12);

Attempt attempt(String id, {String client = clientId, DateTime? at}) =>
    Attempt(id, clientId: client, at: at ?? now);

ElementPatchOp movePatch(
  String opId, {
  String elementId = 'e1',
  int expected = 1,
  double x = 10,
  String? pageId,
  FieldMerge? merge,
}) => ElementPatchOp(
  opId: opId,
  elementPublicId: elementId,
  expectedElementRevision: expected,
  pagePublicId: pageId,
  merge: merge,
  payload: agentPayload(elementId, {
    'position': {'dx': x, 'dy': 0},
  }),
);

ElementDeleteOp elementDelete(
  String opId, {
  String elementId = 'e1',
  String pageId = 'page-a',
  int expected = 1,
}) => ElementDeleteOp(
  opId: opId,
  elementPublicId: elementId,
  pagePublicId: pageId,
  expectedElementRevision: expected,
);

ElementAddOp elementAdd(
  String opId, {
  String elementId = 'e9',
  String pageId = 'page-a',
}) => ElementAddOp(
  opId: opId,
  elementPublicId: elementId,
  pagePublicId: pageId,
  payload: agentPayload(elementId, const {}),
  sortIndex: 0,
);

PageAddOp pageAdd(
  String opId,
  String pageId, {
  int expected = 1,
  String? copyFrom,
}) => PageAddOp(
  opId: opId,
  pagePublicId: pageId,
  sortIndex: 2,
  expectedStrategyRevision: expected,
  name: 'Page 3',
  copyContentFromPagePublicId: copyFrom,
);

PageDeleteOp pageDelete(String opId, String pageId, {int expected = 1}) =>
    PageDeleteOp(
      opId: opId,
      pagePublicId: pageId,
      expectedStrategyRevision: expected,
    );

PageReorderOp pageReorder(String opId, String pageId, {int expected = 1}) =>
    PageReorderOp(
      opId: opId,
      pagePublicId: pageId,
      sortIndex: 0,
      expectedStrategyRevision: expected,
    );

PagePatchOp pageRename(String opId, String pageId, {int expected = 1}) =>
    PagePatchOp(
      opId: opId,
      pagePublicId: pageId,
      expectedPageRevision: expected,
      name: 'Retake',
    );

SeenPage seenOf(String name, {Map<SeenPart, int>? content}) => SeenPage(
  name: name,
  isAttack: true,
  content: ContentSeen(content ?? {const SeenSettings(): 1}),
);

Edit plain(StrategyOp op, {String rowPage = 'page-a'}) =>
    switch (editOf(op, rowPage: rowPage)) {
      EditMade(:final edit) => edit,
      NeedsRowPage() => fail('no page for ${op.opId}'),
    };

QueueEvent userEdits(StrategyOp op, {String rowPage = 'page-a'}) =>
    UserEdited(plain(op, rowPage: rowPage));

QueueEvent deleting(PageDeleteOp op, SeenPage seen) =>
    UserEdited(PageDeleteEdit(op, seen));

QueueEvent answered(OpAnswer answer, {Attempt? by, BaseRow? base}) =>
    OpAnswered(by ?? attempt('a1'), answer, base: base ?? const BaseLacks());

PendingOp pending(
  StrategyOp op,
  PendingState state, {
  int place = 0,
  Work? work,
  Scope scope = const OnPage('page-a'),
  Against? against,
  SendPolicy policy = SendPolicy.checked,
  BaseWait wait = const NoWait(),
}) => PendingOp(
  place: place,
  work: work ?? OpWork(op),
  scope: scope,
  against: against ?? const OnBase(1),
  policy: policy,
  wait: wait,
  state: state,
);

CloudQueue queueOf(
  List<QueueEntry> entries, {
  Standing standing = Standing.good,
  bool connected = false,
  Map<String, SeenPage> checks = const {},
}) => CloudQueue(
  entries: entries,
  standing: standing,
  session: QueueSession(connected: connected, deleteChecks: checks),
);

Stepped stepped(Step step) => switch (step) {
  final Stepped done => done,
  NotApplicable(:final why) => fail('Expected the event to apply: $why'),
};

Inapplicable notApplicable(Step step) => switch (step) {
  Stepped(:final queue) => fail('Expected it not to apply, got $queue'),
  NotApplicable(:final why) => why,
};

CloudQueue run(CloudQueue queue, List<QueueEvent> events, {DateTime? at}) {
  var current = queue;
  for (final event in events) {
    current = stepped(transition(current, event, now: at ?? now)).queue;
  }
  return current;
}

CloudQueue edits(List<StrategyOp> ops) =>
    run(CloudQueue.empty, [for (final op in ops) userEdits(op)]);

PendingOp entryOf(CloudQueue queue, String opId) => switch (queue.entry(opId)) {
  final PendingOp entry => entry,
  final other => fail('$opId is not a pending op: $other'),
};

PendingState stateOf(CloudQueue queue, String opId) =>
    entryOf(queue, opId).state;

List<Hold> holdsFor(CloudQueue queue, String opId, {DateTime? at}) =>
    holdsOf(queue, at ?? now)[opId] ?? const [];

const neverSentFree = Unsent(NeverSent(), Free());

AnswerUnknown unknown(int failures, {Backoff retry = const RetryNow()}) =>
    AnswerUnknown(
      clientId: clientId,
      firstSentAt: now,
      failures: failures,
      retry: retry,
      cause: const TransportCut(TransportFailure.network),
    );
