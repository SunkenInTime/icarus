import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/op_facts.dart'
    show CopyExpanded, CopyNotExpanded, expandCopy;
import 'package:icarus_library/src/cloud/visible.dart';
import 'package:test/test.dart';

import 'support.dart';

export 'support.dart' show fixtureLife;

const clientId = 'client-1';

const build = 'build-1';

final testAccount = Account('account-a');

final otherAccount = Account('account-b');

final now = DateTime.utc(2026, 11, 20, 12, 0, 0, 0, 371);

const testClient = 1;

var _connection = 0;

var _snapshot = 0;

Generation get currentGeneration =>
    Generation(client: testClient, connection: _connection);

ResultPoint tick() => ResultPoint(
  client: testClient,
  connection: _connection,
  snapshot: ++_snapshot,
  serverTime: _snapshot * 1000,
);

ResultPoint get lastPoint => ResultPoint(
  client: testClient,
  connection: _connection,
  snapshot: _snapshot,
  serverTime: _snapshot * 1000,
);

typedef ReadAsked = ({ResultPoint point, int requestedAt});

ReadAsked askRead(CloudQueue queue) =>
    (point: tick(), requestedAt: queue.session.sequence);

ConnectionReturned reconnected() => ConnectionReturned(
  Generation(client: testClient, connection: ++_connection),
);

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

int? lifeOfCheckedRowForTest(StrategyRows rows, StrategyOp op) =>
    switch (switch (checkTargetOf(op)) {
      StrategyTarget() => rows.strategy,
      PageTarget(:final pagePublicId) => rows.page(pagePublicId),
      SettingsTarget(:final pagePublicId) => rows.settingsOf(pagePublicId),
      ElementTarget(:final elementPublicId) => rows.element(elementPublicId),
      LineupTarget(:final lineupPublicId) => rows.lineupGroup(lineupPublicId),
    }) {
      final Row row => createdAtOf(row),
      null => null,
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

StrategyRowSet visibleOf(StrategyRowSet base, CloudQueue queue) =>
    visibleOver(base, queue, const AllPages());

const heldServerTime = 1764000000000;

final class Client {
  Client({StrategyRowSet? base, this.clock}) : base = base ?? initialRows() {
    queue = CloudQueue.start(build: build);
    read(this.base);
  }

  EditAccessConfirmed accessConfirmed(int afterAttempt) => EditAccessConfirmed(
    afterAttempt: afterAttempt,
    session: queue.session.number,
    point: tick(),
  );

  StrategyRowSet base;
  DateTime? clock;
  late CloudQueue queue;
  final effects = <QueueEffect>[];

  DateTime get at => clock ?? now;

  StrategyRowSet get visible => visibleOf(base, queue);

  Duration elapsed = Duration.zero;
  bool holdsServerTime = true;

  Step step(QueueEvent event) {
    if (event is UserEdited &&
        holdsServerTime &&
        queue.session.connected &&
        queue.session.basis == null) {
      _transition(
        ServerTimeHeld(
          heldServerTime,
          at: elapsed,
          session: queue.session.number,
          point: lastPoint,
        ),
      );
    }
    return _transition(switch (event) {
      BatchClaimed(:final clientId, :final opIds, :final at, elapsed: null)
          when holdsServerTime =>
        BatchClaimed(
          clientId: clientId,
          opIds: opIds,
          at: at,
          elapsed: () => elapsed,
        ),
      _ => event,
    });
  }

  Step _transition(QueueEvent event) {
    final result = transition(queue, event, now: at);
    queue = result.queue;
    if (result case Stepped(effects: final made)) effects.addAll(made);
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
    EditMaking made(StrategyOp op) =>
        editOf(op, authored: authored, rowPage: rowPage);
    return UserEdited(switch (made(op)) {
      EditMade(:final edit) => edit,
      NeedsFieldBase() => switch (made(withFieldBase(rows, op))) {
        EditMade(:final edit) => edit,
        _ => fail('cannot edit $op'),
      },
      NeedsRowPage() ||
      NeedsPageDeleteEdit() ||
      CopyMustBeExpanded() => fail('cannot edit $op'),
    });
  }

  void edit(StrategyOp op) {
    if (op case PageAddOp(copyContentFromPagePublicId: _?)) {
      switch (expandCopy(visible, op)) {
        case CopyExpanded(:final ops):
          ops.forEach(edit);
        case CopyNotExpanded(:final result):
          fail('cannot copy: $result');
      }
      return;
    }
    must(editEvent(op));
  }

  int claim(List<String> ids, {String client = clientId}) {
    final result = stepped(
      step(BatchClaimed(clientId: client, opIds: ids, at: at)),
    );
    return result.effects.whereType<SendBatch>().single.attempt;
  }

  List<StrategyOp> lastSent() =>
      effects.whereType<SendBatch>().last.ops.toList();

  void arrive(ArrivedBase base, {ResultPoint? at}) =>
      must(arrival(base, at: at));

  BaseArrived arrival(ArrivedBase base, {ResultPoint? at, int? requestedAt}) =>
      BaseArrived(
        base,
        session: queue.session.number,
        point: at ?? tick(),
        requestedAt: requestedAt ?? queue.session.sequence,
      );

  ResultRefused readRefused(String? page, String problem) => ResultRefused(
    page: page,
    problem: problem,
    session: queue.session.number,
    point: tick(),
    requestedAt: queue.session.sequence,
  );

  void read(StrategyRowSet server, {Iterable<String>? pages}) {
    base = server;
    arrive(headerReadOf(server));
    for (final page in pages ?? server.pages.map((page) => page.publicId)) {
      arrive(pageReadOf(server, page));
    }
  }

  EntryView view(String opId) => entryViews(queue, at)[opId]!;
}

const addedLife = fixtureLife + 1;

StrategyRowSet bornWhereNew(
  StrategyRowSet before,
  Iterable<Row> written,
  int life,
) => before.withRows([
  for (final row in written)
    before.rows.any((held) => held.key == row.key)
        ? bornIn(row, life)
        : bornIn(_withoutLife(row), life),
]);

Row _withoutLife(Row row) {
  JsonObject lifeless(JsonObject fields) =>
      jsonObject({...fields.toMap()}..remove('createdAt'));
  return switch (row) {
    LiveElement() => LiveElement(
      publicId: row.publicId,
      pagePublicId: row.pagePublicId,
      payload: row.payload,
      sortIndex: row.sortIndex,
      revision: row.revision,
      unknownFields: lifeless(row.unknownFields),
    ),
    LiveLineupGroup() => LiveLineupGroup(
      publicId: row.publicId,
      strategyPublicId: row.strategyPublicId,
      pagePublicId: row.pagePublicId,
      payload: row.payload,
      sortIndex: row.sortIndex,
      revision: row.revision,
      unknownFields: lifeless(row.unknownFields),
    ),
    LivePage() => LivePage(
      publicId: row.publicId,
      strategyPublicId: row.strategyPublicId,
      name: row.name,
      isAutoNamed: row.isAutoNamed,
      sortIndex: row.sortIndex,
      isAttack: row.isAttack,
      revision: row.revision,
      unknownFields: lifeless(row.unknownFields),
    ),
    ReadablePageSettings() => ReadablePageSettings(
      pagePublicId: row.pagePublicId,
      settings: row.settings,
      revision: row.revision,
      unknownFields: lifeless(row.unknownFields),
    ),
    _ => row,
  };
}

StrategyRowSet withOp(StrategyRowSet rows, StrategyOp op) =>
    switch (applyOp(rows, op)) {
      final OpApplied done => bornWhereNew(rows, done.rows, addedLife),
      final other => fail('expected $op to apply, got $other'),
    };

HeaderRead headerReadOf(StrategyRowSet rows) => HeaderRead(
  strategy: rows.strategy,
  pages: rows.pages.toList(),
  settings: rows.settings.toList(),
);

ArrivedBase pageReadOf(StrategyRows rows, String page) =>
    switch (rows.page(page)) {
      final row? => PageRead(
        page: row,
        elements: rows.elementsOn(page).toList(),
        lineupGroups: rows.lineupGroupsOn(page).toList(),
      ),
      null => PageGone(page),
    };

Matcher awaitingResult(ResultSubject subject) =>
    isA<AwaitingResult>().having((hold) => hold.subject, 'subject', subject);

Matcher owed({int? unlessLife, int? namedLife}) => isA<ReadOwed>()
    .having((state) => state.unlessLife, 'unlessLife', unlessLife)
    .having((state) => state.namedLife, 'namedLife', namedLife);

Matcher refusedRead(String problem) =>
    isA<ReadRefused>().having((state) => state.problem, 'problem', problem);
