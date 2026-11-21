import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

const clientId = 'client-1';

const build = 'build-1';

final now = DateTime.utc(2026, 11, 20, 12);

ElementPatchOp movePatch(
  String opId, {
  String elementId = 'e1',
  int expected = 1,
  double x = 10,
  double rotation = 0,
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
    if (rotation != 0) 'rotation': rotation,
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
  int sortIndex = 2,
}) => PageAddOp(
  opId: opId,
  pagePublicId: pageId,
  sortIndex: sortIndex,
  expectedStrategyRevision: expected,
  name: 'Page',
  copyContentFromPagePublicId: copyFrom,
);

PageDeleteOp pageDelete(String opId, String pageId, {int expected = 1}) =>
    PageDeleteOp(
      opId: opId,
      pagePublicId: pageId,
      expectedStrategyRevision: expected,
    );

Stepped stepped(Step step) => switch (step) {
  final Stepped done => done,
  NotApplicable(:final why) => fail('Expected the event to apply: $why'),
};

Inapplicable notApplicable(Step step) => switch (step) {
  Stepped() => fail('Expected it not to apply'),
  NotApplicable(:final why) => why,
};

StrategyRowSet initialRows() => strategyRows(
  elements: [
    element('e1'),
    element('e2'),
    element('e3', pageId: 'page-b'),
  ],
);

int? visibleRevision(StrategyRows rows, StrategyOp op) =>
    switch (targetOf(op)) {
      StrategyTarget() => rows.strategy.revision,
      PageTarget(:final pagePublicId) => switch (rows.page(pagePublicId)) {
        final row? => revisionOfRowForTest(row),
        null => null,
      },
      SettingsTarget(:final pagePublicId) => switch (rows.settingsOf(
        pagePublicId,
      )) {
        final row? => revisionOfRowForTest(row),
        null => null,
      },
      ElementTarget(:final elementPublicId) => switch (rows.element(
        elementPublicId,
      )) {
        final row? => revisionOfRowForTest(row),
        null => null,
      },
      LineupTarget(:final lineupPublicId) => switch (rows.lineupGroup(
        lineupPublicId,
      )) {
        final row? => revisionOfRowForTest(row),
        null => null,
      },
    };

int? revisionOfRowForTest(Row row) => switch (row) {
  ReadablePageRow(:final revision) ||
  ReadablePageSettings(:final revision) ||
  ReadableElementRow(:final revision) ||
  ReadableLineupGroupRow(:final revision) ||
  ReadableStrategy(:final revision) => revision,
  _ => null,
};

StrategyOp onVisible(StrategyRows rows, StrategyOp op) =>
    switch ((expectedOf(op), visibleRevision(rows, op))) {
      (_?, final revision?) => rebasedForTest(op, revision),
      _ => op,
    };

StrategyOp rebasedForTest(StrategyOp op, int revision) =>
    switch (StrategyOp.decode({
      ...op.toJson(),
      for (final key in const [
        'expectedStrategyRevision',
        'expectedPageRevision',
        'expectedPageContentRevision',
        'expectedElementRevision',
        'expectedLineupRevision',
      ])
        if (op.toJson().containsKey(key)) key: revision,
    })) {
      Read(:final value) => value,
      CouldNotRead(:final problem) => fail(problem),
    };

StrategyRowSet visibleOf(StrategyRowSet base, CloudQueue queue) {
  var rows = base;
  for (final entry in queue.entries) {
    if (entry is! PendingOp) continue;
    var op = entry.op;
    if ((entry.op, entry.answer) case (
      final PageAddOp add,
      AnsweredApplied(:final revision),
    ) when add.copyContentFromPagePublicId != null) {
      final shown = queue.base.rows[const StrategyTarget()]?.revision ?? -1;
      if (shown >= revision) continue;
      op = PageAddOp(
        opId: add.opId,
        pagePublicId: add.pagePublicId,
        sortIndex: add.sortIndex,
        expectedStrategyRevision: add.expectedStrategyRevision,
        name: add.name,
        isAutoNamed: add.isAutoNamed,
        isAttack: add.isAttack,
        settings: add.settings,
      );
    }
    if (applyOp(rows, onVisible(rows, op)) case final OpApplied applied) {
      rows = rows.withRows(applied.rows);
    }
  }
  return rows;
}

BaseFacts factsOf(StrategyRowSet rows) {
  var queue = CloudQueue.start(build: build);
  queue = stepped(
    transition(
      queue,
      BaseArrived(
        HeaderRead(
          strategy: rows.strategy,
          pages: rows.pages.toList(),
          settings: rows.settings.toList(),
        ),
      ),
      now: now,
    ),
  ).queue;
  for (final page in rows.pages) {
    queue = stepped(
      transition(
        queue,
        BaseArrived(
          PageRead(
            page: page,
            settings: rows.settingsOf(page.publicId)!,
            elements: rows.elementsOn(page.publicId).toList(),
            lineupGroups: rows.lineupGroupsOn(page.publicId).toList(),
          ),
        ),
        now: now,
      ),
    ).queue;
  }
  return queue.base;
}

final class Client {
  Client({StrategyRowSet? base, this.clock}) : base = base ?? initialRows() {
    queue = CloudQueue.start(build: build, base: factsOf(this.base));
  }

  StrategyRowSet base;
  DateTime? clock;
  late CloudQueue queue;
  final effects = <QueueEffect>[];

  DateTime get at => clock ?? now;

  StrategyRowSet get visible => visibleOf(base, queue);

  Step step(QueueEvent event) {
    final result = transition(queue, event, now: at);
    if (result case Stepped(queue: final next, effects: final made)) {
      queue = next;
      effects.addAll(made);
    }
    return result;
  }

  void must(QueueEvent event) => stepped(step(event));

  QueueEvent editEvent(StrategyOp op) {
    final rows = visible;
    final authored = authoredFor(rows, op);
    if (op is PageDeleteOp) {
      return UserEdited(
        PageDeleteEdit(op, seenPageIn(rows, op.pagePublicId), authored),
      );
    }
    final rowPage = switch (op) {
      ElementPatchOp(:final elementPublicId) =>
        rows.element(elementPublicId)?.pagePublicId,
      LineupGroupPatchOp(:final lineupPublicId) =>
        rows.lineupGroup(lineupPublicId)?.pagePublicId,
      _ => null,
    };
    return UserEdited(switch (editOf(
      op,
      authored: authored,
      rowPage: rowPage,
    )) {
      EditMade(:final edit) => edit,
      NeedsRowPage() || NeedsPageDeleteEdit() => fail('cannot edit $op'),
    });
  }

  void edit(StrategyOp op) => must(editEvent(op));

  int claim(List<String> ids, {String client = clientId}) {
    final result = stepped(
      transition(
        queue,
        BatchClaimed(clientId: client, opIds: ids, at: at),
        now: at,
      ),
    );
    queue = result.queue;
    effects.addAll(result.effects);
    return result.effects.whereType<SendBatch>().single.attempt;
  }

  List<StrategyOp> lastSent() =>
      effects.whereType<SendBatch>().last.ops.toList();

  void read(StrategyRowSet server, {Iterable<String>? pages}) {
    base = server;
    must(
      BaseArrived(
        HeaderRead(
          strategy: server.strategy,
          pages: server.pages.toList(),
          settings: server.settings.toList(),
        ),
      ),
    );
    for (final page in pages ?? server.pages.map((page) => page.publicId)) {
      if (server.page(page) case final row?) {
        must(
          BaseArrived(
            PageRead(
              page: row,
              settings: server.settingsOf(page)!,
              elements: server.elementsOn(page).toList(),
              lineupGroups: server.lineupGroupsOn(page).toList(),
            ),
          ),
        );
      }
    }
  }

  EntryView view(String opId) => entryViews(queue, at)[opId]!;
}

StrategyRowSet withOp(StrategyRowSet rows, StrategyOp op) =>
    switch (applyOp(rows, op)) {
      final OpApplied done => rows.withRows(done.rows),
      final other => fail('expected $op to apply, got $other'),
    };
