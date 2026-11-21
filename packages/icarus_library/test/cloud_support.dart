import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

const clientId = 'client-1';

final now = DateTime.utc(2026, 11, 20, 12);

ElementPatchOp movePatch(
  String opId, {
  String elementId = 'e1',
  int expected = 1,
  double x = 10,
}) => ElementPatchOp(
  opId: opId,
  elementPublicId: elementId,
  expectedElementRevision: expected,
  payload: agentPayload(elementId, {
    'position': {'dx': x, 'dy': 0},
  }),
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

PageAddOp pageAdd(String opId, String pageId, {int expected = 1}) => PageAddOp(
  opId: opId,
  pagePublicId: pageId,
  sortIndex: 2,
  expectedStrategyRevision: expected,
  name: 'Page 3',
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

PendingOp pending(
  StrategyOp op,
  PendingState state, {
  DeleteCheck check = const NoCheck(),
}) => PendingOp(op: op, clientId: clientId, check: check, state: state);

CloudQueue queueOf(
  List<QueueEntry> entries, {
  Set<String> checked = const {},
}) => CloudQueue(entries: entries, deletesCheckedThisSession: checked);

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

CloudQueue edits(List<StrategyOp> ops) => run(CloudQueue.empty, [
  for (final op in ops) UserEdited(PlainEdit(op), clientId: clientId),
]);

PendingState stateOf(CloudQueue queue, String opId) =>
    switch (queue.entry(opId)) {
      PendingOp(:final state) => state,
      final other => fail('$opId is not a pending op: $other'),
    };

const neverSentFree = Unsent(NeverSent(), Free());
