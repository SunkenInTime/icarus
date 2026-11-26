import 'package:collection/collection.dart';

import '../rows.dart';
import '../strategy_rows.dart';
import 'events.dart';
import 'op_facts.dart';
import 'pending.dart';
import 'version.dart';

bool shownTakesChecked =
    const bool.fromEnvironment('ICARUS_DRIVE') ||
    !const bool.fromEnvironment('dart.vm.product');

bool shownTakesReuse = true;

final class ShownWork {
  int contentRowsDigested = 0;

  void reset() {
    contentRowsDigested = 0;
  }
}

final shownWork = ShownWork();

final class TakesDiffer extends StateError {
  TakesDiffer(String page)
    : super(
        'page $page taken with digests of this run differs from the same '
        'result taken from scratch',
      );

  TakesDiffer.group(String? page)
    : super(
        'the stored results of ${page ?? 'the page list'} kept from before '
        'differ from encoding them again',
      );

  TakesDiffer.copies(String id)
    : super('the store holds $id on more than one page');

  TakesDiffer.missing(String id)
    : super(
        'item $id is held unchanged by the queue, but the store has no '
        'readable copy of it',
      );

  TakesDiffer.stored(String id)
    : super(
        'item $id arrived at the revision and life the store holds, but '
        'differs from the stored copy',
      );
}

final class ShownRow {
  const ShownRow({
    required this.page,
    required this.revision,
    required this.digest,
    this.life,
    this.digestedThisRun = false,
    this.here = true,
  });

  final String page;
  final int? revision;
  final int? life;
  final String digest;
  final bool digestedThisRun;
  final bool here;

  ShownRow get notHere => ShownRow(
    page: page,
    revision: revision,
    life: life,
    digest: digest,
    digestedThisRun: digestedThisRun,
    here: false,
  );

  bool holdsDigestOf(Row row, String page) =>
      here &&
      digestedThisRun &&
      revision != null &&
      this.page == page &&
      revision == revisionOfRow(row) &&
      life == createdAtOf(row);

  Version? get version => switch (revision) {
    final revision? => Version(revision, life: life),
    null => null,
  };

  @override
  bool operator ==(Object other) =>
      other is ShownRow &&
      other.page == page &&
      other.revision == revision &&
      other.life == life &&
      other.digest == digest &&
      other.here == here;

  @override
  int get hashCode => Object.hash(page, revision, life, digest, here);
}

final class Freshness {
  Freshness._({
    required this.listSinceTouch,
    required Set<String> listed,
    required Set<String> touchedSinceList,
    required Set<String> pagesSinceTouch,
    required Set<String> goneByResult,
  }) : listed = Set.unmodifiable(listed),
       goneByResult = Set.unmodifiable(goneByResult),
       touchedSinceList = Set.unmodifiable(touchedSinceList),
       pagesSinceTouch = Set.unmodifiable(pagesSinceTouch);

  static final none = Freshness._(
    listSinceTouch: false,
    listed: const {},
    touchedSinceList: const {},
    pagesSinceTouch: const {},
    goneByResult: const {},
  );

  final bool listSinceTouch;
  final Set<String> goneByResult;
  final Set<String> listed;
  final Set<String> touchedSinceList;
  final Set<String> pagesSinceTouch;

  Freshness afterList(Iterable<String> live) {
    final listedNow = {...live};
    return Freshness._(
      listSinceTouch: true,
      listed: listedNow,
      touchedSinceList: const {},
      pagesSinceTouch: pagesSinceTouch,
      goneByResult: goneByResult,
    );
  }

  Freshness afterPage(String page, {required bool gone}) => Freshness._(
    listSinceTouch: listSinceTouch,
    listed: listed,
    touchedSinceList: touchedSinceList,
    pagesSinceTouch: {...pagesSinceTouch, page},
    goneByResult: gone
        ? {...goneByResult, page}
        : ({...goneByResult}..remove(page)),
  );

  Freshness touched(Iterable<String> pages, {required bool list}) =>
      Freshness._(
        listSinceTouch: listSinceTouch && !list,
        listed: listed,
        touchedSinceList: {...touchedSinceList, ...pages},
        pagesSinceTouch: list
            ? const {}
            : ({...pagesSinceTouch}..removeAll(pages)),
        goneByResult: goneByResult,
      );

  bool listFreshFor(String page) =>
      listSinceTouch && !touchedSinceList.contains(page);

  bool pageFreshFor(String page) => pagesSinceTouch.contains(page);

  bool freshFor(String page) =>
      listFreshFor(page) && (pageFreshFor(page) || !listed.contains(page));

  bool disagreeOn(String page) =>
      listFreshFor(page) &&
      pageFreshFor(page) &&
      listed.contains(page) == goneByResult.contains(page);

  @override
  bool operator ==(Object other) =>
      other is Freshness &&
      other.listSinceTouch == listSinceTouch &&
      const SetEquality<String>().equals(other.listed, listed) &&
      const SetEquality<String>().equals(
        other.touchedSinceList,
        touchedSinceList,
      ) &&
      const SetEquality<String>().equals(
        other.pagesSinceTouch,
        pagesSinceTouch,
      ) &&
      const SetEquality<String>().equals(other.goneByResult, goneByResult);

  @override
  int get hashCode => Object.hash(listSinceTouch, listed.length);
}

final class ReadStart {
  const ReadStart({required this.session, required this.sequence});

  static const beforeAnyRead = ReadStart(session: 0, sequence: 0);

  final int session;
  final int sequence;

  bool isBefore(ReadStart other) =>
      session < other.session ||
      (session == other.session && sequence < other.sequence);

  @override
  bool operator ==(Object other) =>
      other is ReadStart &&
      other.session == session &&
      other.sequence == sequence;

  @override
  int get hashCode => Object.hash(session, sequence);

  @override
  String toString() => 'session $session, step $sequence';
}

bool paidBy(ReadState state, ReadStart? started) => switch (state) {
  ReadOwed(:final since) ||
  ReadRefused(:final since) => started != null && !started.isBefore(since),
  NotReadThisSession() || ReadThisSession() => true,
};

sealed class ReadState {
  const ReadState();

  ReadState get inNewSession => this;
}

final class NotReadThisSession extends ReadState {
  const NotReadThisSession();

  @override
  bool operator ==(Object other) => other is NotReadThisSession;

  @override
  int get hashCode => (NotReadThisSession).hashCode;

  @override
  String toString() => 'not read this session';
}

final class ReadThisSession extends ReadState {
  const ReadThisSession();

  @override
  ReadState get inNewSession => const NotReadThisSession();

  @override
  bool operator ==(Object other) => other is ReadThisSession;

  @override
  int get hashCode => (ReadThisSession).hashCode;

  @override
  String toString() => 'read this session';
}

final class ReadOwed extends ReadState {
  const ReadOwed({this.unlessLife, this.namedLife, required this.since});

  final int? unlessLife;
  final int? namedLife;
  final ReadStart since;

  @override
  bool operator ==(Object other) =>
      other is ReadOwed &&
      other.unlessLife == unlessLife &&
      other.namedLife == namedLife &&
      other.since == since;

  @override
  int get hashCode => Object.hash(ReadOwed, unlessLife, namedLife, since);

  @override
  String toString() => switch ((unlessLife, namedLife)) {
    (null, _) => 'owed',
    (final refused?, null) =>
      'owed by a list of another life than $refused, read after the refusal',
    (_, final named?) => 'owed by a list of life $named or later',
  };
}

final class ReadRefused extends ReadState {
  const ReadRefused(
    this.problem, {
    this.unlessLife,
    this.namedLife,
    required this.since,
  });

  final String problem;
  final int? unlessLife;
  final int? namedLife;
  final ReadStart since;

  @override
  bool operator ==(Object other) =>
      other is ReadRefused &&
      other.problem == problem &&
      other.unlessLife == unlessLife &&
      other.namedLife == namedLife &&
      other.since == since;

  @override
  int get hashCode =>
      Object.hash(ReadRefused, problem, unlessLife, namedLife, since);

  @override
  String toString() => switch ((unlessLife, namedLife)) {
    (null, _) => 'refused: $problem',
    (final refused?, null) =>
      'refused: $problem, owed by a list of another life than $refused, read '
          'after the refusal',
    (_, final named?) =>
      'refused: $problem, owed by a list of life $named or later',
  };
}

int? namedLifeOf(ReadState state) => switch (state) {
  ReadOwed(:final namedLife) || ReadRefused(:final namedLife) => namedLife,
  NotReadThisSession() || ReadThisSession() => null,
};

bool isDebt(ReadState state) => state is ReadOwed || state is ReadRefused;

bool replaces(ShownRow? held, Row incoming) =>
    held == null || !_outranks(held.version, versionOfRow(incoming));

enum KeptBecause { heldIsNewer, leftByANewerResult }

sealed class Repair {
  const Repair(this.target, {required this.page});

  final Target target;
  final String page;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is Repair &&
      other.target == target &&
      other.page == page &&
      other._version == _version;

  Version? get _version => null;

  @override
  int get hashCode => Object.hash(runtimeType, target, page, _version);
}

final class TakenFromThisDevice extends Repair {
  const TakenFromThisDevice(super.target, {required super.page, this.version});

  final Version? version;

  @override
  Version? get _version => version;

  @override
  String toString() => '$target on $page taken as stored here, at $version';
}

final class SecondCopyRemoved extends Repair {
  const SecondCopyRemoved(super.target, {required super.page});

  @override
  String toString() => 'a second copy of $target on $page removed';
}

final class NoCopyOnThisDevice extends Repair {
  const NoCopyOnThisDevice(super.target, {required super.page, this.version});

  final Version? version;

  @override
  Version? get _version => version;

  @override
  String toString() => '$target on $page, at $version, has no copy here';
}

final class DamagedOnThisDevice extends Repair {
  const DamagedOnThisDevice(super.target, {required super.page, this.version});

  final Version? version;

  @override
  Version? get _version => version;

  @override
  String toString() => '$target on $page, at $version, is damaged here';
}

final class HeldCopy {
  const HeldCopy(this.page, [this.row]);

  final String page;
  final Row? row;

  Version? get version => switch (row) {
    final row? => versionOfRow(row),
    null => null,
  };

  bool isBetterThan(HeldCopy other) {
    if (_outranks(version, other.version)) return true;
    if (_outranks(other.version, version)) return false;
    return page.compareTo(other.page) < 0;
  }
}

final class HeaderHeld {
  const HeaderHeld({
    required this.strategy,
    required this.pages,
    required this.settings,
    required this.damaged,
  });

  final StrategyRow? strategy;
  final Iterable<PageRow> pages;
  final Iterable<PageSettingsRow> settings;
  final bool Function(Target target) damaged;
}

final class Reconciled {
  Reconciled(
    this.shown, {
    List<RowDecision> decisions = const [],
    List<Repair> repairs = const [],
  }) : decisions = List.unmodifiable(decisions),
       repairs = List.unmodifiable(repairs);

  final Shown shown;
  final List<RowDecision> decisions;
  final List<Repair> repairs;
}

final class Removed {
  const Removed(this.order, {required this.held});

  final ReadStart order;
  final Version? held;

  bool keepsOut(Row row, ReadStart? started) =>
      started != null &&
      started.isBefore(order) &&
      switch ((versionOfRow(row), held)) {
        (final incoming?, final held?) => !(incoming > held),
        (null, _) => true,
        (_?, null) => false,
      };

  @override
  bool operator ==(Object other) =>
      other is Removed && other.order == order && other.held == held;

  @override
  int get hashCode => Object.hash(order, held);

  @override
  String toString() => 'removed at $order, last held at $held';
}

sealed class RowDecision {
  const RowDecision();
}

final class RowTaken extends RowDecision {
  const RowTaken(this.row);

  final Row row;

  @override
  bool operator ==(Object other) =>
      other is RowTaken && other.row.key == row.key && other.row == row;

  @override
  int get hashCode => Object.hash(RowTaken, row.key);

  @override
  String toString() => 'taken ${row.key}';
}

final class RowKept extends RowDecision {
  const RowKept(this.row, this.because);

  final Row row;
  final KeptBecause because;

  @override
  bool operator ==(Object other) =>
      other is RowKept && other.row.key == row.key && other.because == because;

  @override
  int get hashCode => Object.hash(RowKept, row.key, because);

  @override
  String toString() => 'kept ${row.key}: ${because.name}';
}

final class RowUnchanged extends RowDecision {
  const RowUnchanged(this.row);

  final Row row;

  @override
  bool operator ==(Object other) =>
      other is RowUnchanged && other.row.key == row.key && other.row == row;

  @override
  int get hashCode => Object.hash(RowUnchanged, row.key);

  @override
  String toString() => 'unchanged ${row.key}';
}

final class ItemLeft extends RowDecision {
  const ItemLeft(this.target, {required this.page});

  final Target target;
  final String page;

  @override
  bool operator ==(Object other) =>
      other is ItemLeft && other.target == target && other.page == page;

  @override
  int get hashCode => Object.hash(ItemLeft, target, page);

  @override
  String toString() => '$target left page $page';
}

final class PageLeft extends RowDecision {
  const PageLeft(this.page);

  final String page;

  @override
  bool operator ==(Object other) => other is PageLeft && other.page == page;

  @override
  int get hashCode => Object.hash(PageLeft, page);

  @override
  String toString() => 'page $page left';
}

final class SettingsLeft extends RowDecision {
  const SettingsLeft(this.page);

  final String page;

  @override
  bool operator ==(Object other) => other is SettingsLeft && other.page == page;

  @override
  int get hashCode => Object.hash(SettingsLeft, page);

  @override
  String toString() => 'settings of $page left';
}

final class UnreadableLeft extends RowDecision {
  UnreadableLeft(this.page, Iterable<Row> carried)
    : carried = List.unmodifiable(carried);

  final String page;
  final List<Row> carried;

  @override
  bool operator ==(Object other) =>
      other is UnreadableLeft &&
      other.page == page &&
      const SetEquality<RowKey>().equals(
        {for (final row in other.carried) row.key},
        {for (final row in carried) row.key},
      );

  @override
  int get hashCode => Object.hash(UnreadableLeft, page, carried.length);

  @override
  String toString() => 'unreadable rows of $page that the result left out left';
}

final class Taken {
  Taken(this.shown, Iterable<RowDecision> decisions)
    : decisions = List.unmodifiable(decisions);

  final Shown shown;
  final List<RowDecision> decisions;

  @override
  bool operator ==(Object other) =>
      other is Taken &&
      other.shown == shown &&
      const ListEquality<RowDecision>().equals(other.decisions, decisions);

  @override
  int get hashCode => Object.hash(shown, decisions.length);
}

final class Shown {
  Shown({
    required this.strategy,
    required Map<String, ShownRow> pages,
    required Map<String, ShownRow> settings,
    required Map<String, Map<SeenPart, String>> content,
    required Map<Target, ShownRow> rows,
    Map<String, ShownRow> trashed = const {},
    Map<Target, Removed> tombstones = const {},
    this.list = const NotReadThisSession(),
    Map<String, ReadState> pageReads = const {},
    Set<String> goneThisSession = const {},
    Map<Target, Version> highest = const {},
    Freshness? fresh,
    this.listTaken,
    Map<String, ReadStart> pagesTaken = const {},
    this.fence,
  }) : fresh = fresh ?? Freshness.none,
       pagesTaken = Map.unmodifiable(pagesTaken),
       pageReads = Map.unmodifiable({
         for (final MapEntry(:key, :value) in pageReads.entries)
           if (value is! NotReadThisSession) key: value,
       }),
       goneThisSession = Set.unmodifiable(goneThisSession),
       highest = Map.unmodifiable(highest),
       pages = Map.unmodifiable(pages),
       trashed = Map.unmodifiable(trashed),
       tombstones = Map.unmodifiable(tombstones),
       settings = Map.unmodifiable(settings),
       content = Map.unmodifiable(content),
       rows = Map.unmodifiable(rows);

  static final nothing = Shown(
    strategy: null,
    pages: const {},
    settings: const {},
    content: const {},
    rows: const {},
  );

  factory Shown.of(StrategyRowSet rows, {required Iterable<String> readPages}) {
    final read = {...readPages};
    var fresh = Freshness.none.afterList([
      for (final page in rows.pages)
        if (page is! TrashedPage) page.publicId,
    ]);
    for (final page in read) {
      fresh = fresh.afterPage(page, gone: false);
    }
    return Shown(
      fresh: fresh,
      list: const ReadThisSession(),
      pageReads: {for (final page in read) page: const ReadThisSession()},
      strategy: _strategyRow(rows.strategy, rows.pages),
      pages: {
        for (final page in rows.pages)
          if (page is! TrashedPage) page.publicId: _rowOf(page, page),
      },
      trashed: {
        for (final page in rows.pages)
          if (page is TrashedPage) page.publicId: _rowOf(page, page),
      },
      settings: {
        for (final row in rows.settings)
          row.pagePublicId: _rowOf(row, row.pagePublicId),
      },
      content: {
        for (final page in read)
          page: liveContentOn([
            ...rows.elementsOn(page),
            ...rows.lineupGroupsOn(page),
          ], page),
      },
      rows: {
        for (final page in read) ...{
          for (final row in rows.elementsOn(page))
            ElementTarget(row.publicId): _rowOf(row, page),
          for (final row in rows.lineupGroupsOn(page))
            LineupTarget(row.publicId): _rowOf(row, page),
        },
      },
      highest: {
        const StrategyTarget(): ?versionOfRow(rows.strategy),
        for (final page in rows.pages)
          if (page is! TrashedPage)
            PageTarget(page.publicId): ?versionOfRow(page),
        for (final row in rows.settings)
          SettingsTarget(row.pagePublicId): ?versionOfRow(row),
        for (final page in read) ...{
          for (final row in rows.elementsOn(page))
            ElementTarget(row.publicId): ?versionOfRow(row),
          for (final row in rows.lineupGroupsOn(page))
            LineupTarget(row.publicId): ?versionOfRow(row),
        },
      },
    );
  }

  final ShownRow? strategy;
  final Freshness fresh;
  final ReadState list;
  final Map<String, ReadState> pageReads;
  final ReadStart? listTaken;
  final Map<String, ReadStart> pagesTaken;
  final ReadStart? fence;

  ReadStart? owedSince(ArrivedBase result) => switch (switch (result) {
    HeaderRead() || StrategyGone() => list,
    PageRead(:final page) => pageRead(page.publicId),
    PageGone(:final pagePublicId) => pageRead(pagePublicId),
  }) {
    ReadOwed(:final since) || ReadRefused(:final since) => since,
    NotReadThisSession() || ReadThisSession() => null,
  };

  Shown fencedAt(ReadStart fence, {required Shown after}) => Shown(
    strategy: strategy,
    pages: pages,
    trashed: trashed,
    tombstones: tombstones,
    settings: settings,
    content: content,
    rows: rows,
    list: list,
    pageReads: pageReads,
    goneThisSession: goneThisSession,
    highest: highest,
    fresh: fresh,
    listTaken: listTaken ?? after.listTaken,
    pagesTaken: {...after.pagesTaken, ...pagesTaken},
    fence: fence,
  );

  ReadStart? takenFor(ArrivedBase result) => switch (result) {
    HeaderRead() || StrategyGone() => listTaken,
    PageRead(:final page) => pagesTaken[page.publicId],
    PageGone(:final pagePublicId) => pagesTaken[pagePublicId],
  };

  int? get strategyRevision => strategy?.revision;

  static ShownRow _strategyRow(StrategyRow row, Iterable<PageRow> pages) =>
      ShownRow(
        page: '',
        revision: revisionOfRow(row),
        life: createdAtOf(row),
        digest: strategyDigest(row, pages),
      );
  final Set<String> goneThisSession;
  final Map<Target, Version> highest;
  final Map<String, ShownRow> pages;
  final Map<String, ShownRow> trashed;
  final Map<Target, Removed> tombstones;
  final Map<String, ShownRow> settings;
  final Map<String, Map<SeenPart, String>> content;
  final Map<Target, ShownRow> rows;

  bool get headerThisSession => list is ReadThisSession;

  bool pageReadThisSession(String page) => pageReads[page] is ReadThisSession;

  ReadState pageRead(String page) =>
      pageReads[page] ?? const NotReadThisSession();

  Set<String> get pagesToRead => {
    for (final page in pages.keys)
      if (!content.containsKey(page) || pageRead(page) is ReadOwed) page,
  };

  static ShownRow _rowOf(Row row, Object page) => ShownRow(
    page: switch (page) {
      final String id => id,
      PageRow(:final publicId) => publicId,
      _ => '',
    },
    revision: revisionOfRow(row),
    life: createdAtOf(row),
    digest: rowDigest(row),
    digestedThisRun: true,
  );

  static ShownRow _digested(Row row, String page) {
    shownWork.contentRowsDigested++;
    return _rowOf(row, page);
  }

  Shown withTrashedPages(Iterable<PageRow> held) => _with(
    trashed: {
      for (final page in held)
        if (page is TrashedPage) page.publicId: _rowOf(page, page),
    },
  );

  Reconciled withHeaderHeld(HeaderHeld held) {
    final repairs = <Repair>[];
    var strategyRow = strategy;
    final storedStrategy = switch (held.strategy) {
      final row? => _strategyRow(row, held.pages),
      null => null,
    };
    if (storedStrategy != null &&
        (strategyRow == null ||
            !strategyRow.here ||
            strategyRow.version != storedStrategy.version)) {
      strategyRow = storedStrategy;
      repairs.add(
        TakenFromThisDevice(
          const StrategyTarget(),
          page: '',
          version: storedStrategy.version,
        ),
      );
    }
    final nextPages = {...pages};
    final nextTrashed = {...trashed};
    final raised = <Target, Version>{};
    final stored = <String>{};
    for (final row in held.pages) {
      final id = row.publicId;
      stored.add(id);
      final atStore = _rowOf(row, row);
      final isTrashed = row is TrashedPage;
      final held = (isTrashed ? trashed : pages)[id];
      if (held == atStore) continue;
      nextPages.remove(id);
      nextTrashed.remove(id);
      (isTrashed ? nextTrashed : nextPages)[id] = atStore;
      if ((isTrashed, atStore.version) case (false, final version?)) {
        raised[PageTarget(id)] = version;
      }
      repairs.add(
        TakenFromThisDevice(PageTarget(id), page: id, version: atStore.version),
      );
    }
    for (final id in {...pages.keys, ...trashed.keys}) {
      if (stored.contains(id)) continue;
      final inLive = nextPages.containsKey(id);
      final row = (inLive ? nextPages : nextTrashed)[id]!;
      if (!row.here) continue;
      (inLive ? nextPages : nextTrashed)[id] = row.notHere;
      repairs.add(_unreadable(held, PageTarget(id), id, row));
    }
    final nextSettings = {...settings};
    final storedSettings = <String>{};
    for (final row in held.settings) {
      final id = row.pagePublicId;
      storedSettings.add(id);
      final atStore = _rowOf(row, id);
      if (settings[id] == atStore) continue;
      nextSettings[id] = atStore;
      if (atStore.version case final version?) {
        raised[SettingsTarget(id)] = version;
      }
      repairs.add(
        TakenFromThisDevice(
          SettingsTarget(id),
          page: id,
          version: atStore.version,
        ),
      );
    }
    for (final MapEntry(key: id, value: row) in settings.entries) {
      if (storedSettings.contains(id) || !row.here) continue;
      nextSettings[id] = row.notHere;
      repairs.add(_unreadable(held, SettingsTarget(id), id, row));
    }
    if (repairs.isEmpty) return Reconciled(this);
    if (strategyRow?.version case final version?) {
      raised[const StrategyTarget()] = version;
    }
    return Reconciled(
      _with(
        strategy: strategyRow,
        pages: nextPages,
        trashed: nextTrashed,
        settings: nextSettings,
        highest: _raised(highest, raised),
      ),
      repairs: repairs,
    );
  }

  static Repair _unreadable(
    HeaderHeld held,
    Target target,
    String page,
    ShownRow row,
  ) => held.damaged(target)
      ? DamagedOnThisDevice(target, page: page, version: row.version)
      : NoCopyOnThisDevice(target, page: page, version: row.version);

  Reconciled withItemsHeld(
    Map<Target, List<HeldCopy>> copies, {
    required bool compareDigests,
  }) {
    final repairs = <Repair>[];
    final decisions = <RowDecision>[];
    Map<Target, ShownRow>? changed;
    Map<String, Map<SeenPart, String>>? changedContent;
    Map<Target, ShownRow> next() => changed ??= {...rows};
    Map<String, Map<SeenPart, String>> nextContent() => changedContent ??= {
      for (final MapEntry(:key, :value) in content.entries) key: {...value},
    };
    final raised = <Target, Version>{};
    for (final MapEntry(key: target, value: held) in copies.entries) {
      final shown = rows[target];
      HeldCopy? kept;
      for (final copy in held) {
        if (shown != null && copy.page == shown.page) kept = copy;
      }
      if (kept == null) {
        for (final copy in held) {
          if (kept == null || copy.isBetterThan(kept)) kept = copy;
        }
      }
      for (final copy in held) {
        if (identical(copy, kept)) continue;
        decisions.add(ItemLeft(target, page: copy.page));
        repairs.add(SecondCopyRemoved(target, page: copy.page));
      }
      switch ((kept, shown)) {
        case (null, null):
          break;
        case (null, final shown?):
          if (!shown.here) break;
          next()[target] = shown.notHere;
          repairs.add(
            NoCopyOnThisDevice(
              target,
              page: shown.page,
              version: shown.version,
            ),
          );
        case (HeldCopy(row: null, :final page), final shown)
            when shown != null && shown.page == page:
          if (!shown.here) break;
          next()[target] = shown.notHere;
          repairs.add(
            DamagedOnThisDevice(target, page: page, version: shown.version),
          );
        case (HeldCopy(row: null, :final page), final shown):
          next()[target] = ShownRow(
            page: page,
            revision: null,
            digest: '',
          ).notHere;
          _withoutPart(nextContent(), target, shown?.page);
          repairs.add(DamagedOnThisDevice(target, page: page));
        case (HeldCopy(:final row?, :final page), final shown):
          if (shown != null &&
              shown.here &&
              shown.page == page &&
              shown.version == versionOfRow(row) &&
              (!compareDigests || shown.digest == rowDigest(row))) {
            break;
          }
          final atStore = _rowOf(row, page);
          next()[target] = atStore;
          _withoutPart(nextContent(), target, shown?.page);
          if (_partOf(target) case final part?
              when lifeOfRow(row) == Life.live) {
            (nextContent()[page] ??= {})[part] = atStore.digest;
          }
          if (atStore.version case final version?) raised[target] = version;
          repairs.add(
            TakenFromThisDevice(target, page: page, version: atStore.version),
          );
      }
    }
    if (repairs.isEmpty) return Reconciled(this);
    return Reconciled(
      _with(
        rows: changed,
        content: switch (changedContent) {
          final changed? => {
            for (final MapEntry(:key, :value) in changed.entries)
              if (content.containsKey(key) || value.isNotEmpty) key: value,
          },
          null => null,
        },
        highest: _raised(highest, raised),
      ),
      decisions: decisions,
      repairs: repairs,
    );
  }

  static void _withoutPart(
    Map<String, Map<SeenPart, String>> content,
    Target target,
    String? page,
  ) {
    if (page == null) return;
    if (_partOf(target) case final part?) content[page]?.remove(part);
  }

  Shown _with({
    Freshness? fresh,
    ReadState? list,
    Map<String, ReadState>? pageReads,
    Set<String>? goneThisSession,
    Map<Target, Version>? highest,
    Map<String, ShownRow>? pages,
    Map<String, ShownRow>? trashed,
    Map<Target, Removed>? tombstones,
    Map<String, ShownRow>? settings,
    Map<String, Map<SeenPart, String>>? content,
    Map<Target, ShownRow>? rows,
    ReadStart? listTaken,
    Map<String, ReadStart>? pagesTaken,
    ShownRow? strategy,
  }) => Shown(
    listTaken: listTaken ?? this.listTaken,
    pagesTaken: pagesTaken ?? this.pagesTaken,
    fence: fence,
    fresh: fresh ?? this.fresh,
    list: list ?? this.list,
    pageReads: pageReads ?? this.pageReads,
    goneThisSession: goneThisSession ?? this.goneThisSession,
    highest: highest ?? this.highest,
    strategy: strategy ?? this.strategy,
    pages: pages ?? this.pages,
    trashed: trashed ?? this.trashed,
    tombstones: tombstones ?? this.tombstones,
    settings: settings ?? this.settings,
    content: content ?? this.content,
    rows: rows ?? this.rows,
  );

  Set<String> get knownPages => {
    ...pages.keys,
    ...trashed.keys,
    ...settings.keys,
    for (final row in rows.values) row.page,
  };

  Map<Target, Removed> _removedOn(
    bool Function(String page) gone,
    ReadStart? started,
  ) => {
    ...tombstones,
    if (started != null)
      for (final MapEntry(:key, :value) in rows.entries)
        if (gone(value.page)) key: Removed(started, held: value.version),
  };

  Taken taken(ArrivedBase result, {required ReadStart? started}) =>
      switch (result) {
        HeaderRead() => _withList(result, started),
        PageRead(:final page, :final elements, :final lineupGroups) =>
          _checkedTake(
            page.publicId,
            (reuse) => _withPage(
              page,
              [...elements, ...lineupGroups],
              paid: paidBy(pageRead(page.publicId), started),
              started: started,
              reuse: reuse,
            ),
          ),
        PageGone(:final pagePublicId) => Taken(
          _with(
            pagesTaken: {...pagesTaken, pagePublicId: ?started},
            fresh: fresh.afterPage(pagePublicId, gone: true),
            pageReads: {...pageReads}..remove(pagePublicId),
            goneThisSession: {...goneThisSession, pagePublicId},
            pages: {...pages}..remove(pagePublicId),
            trashed: {...trashed}..remove(pagePublicId),
            settings: {...settings}..remove(pagePublicId),
            content: {...content}..remove(pagePublicId),
            tombstones: _removedOn((page) => page == pagePublicId, started),
            rows: {
              for (final MapEntry(:key, :value) in rows.entries)
                if (value.page != pagePublicId) key: value,
            },
          ),
          [PageLeft(pagePublicId)],
        ),
        StrategyGone() => Taken(
          _with(
            listTaken: started,
            list: paidBy(list, started) ? const ReadThisSession() : list,
            pageReads: {
              for (final MapEntry(:key, :value) in pageReads.entries)
                if (!isDebt(value) || !paidBy(value, started)) key: value,
            },
          ),
          const [],
        ),
      };

  Taken _withList(HeaderRead result, ReadStart? started) {
    final HeaderRead(strategy: strategyRow, pages: listed, :settings) = result;
    final listedIds = {for (final page in listed) page.publicId};
    final decisions = <RowDecision>[
      for (final page in knownPages)
        if (!listedIds.contains(page)) PageLeft(page),
      RowTaken(strategyRow),
    ];
    final nextPages = <String, ShownRow>{};
    final nextTrashed = <String, ShownRow>{};
    for (final page in listed) {
      final id = page.publicId;
      final heldLive = pages[id];
      final held = heldLive ?? trashed[id];
      if (replaces(held, page)) {
        decisions.add(RowTaken(page));
        (page is TrashedPage ? nextTrashed : nextPages)[id] = _rowOf(
          page,
          page,
        );
      } else {
        decisions.add(RowKept(page, KeptBecause.heldIsNewer));
        (heldLive != null ? nextPages : nextTrashed)[id] = held!;
      }
    }
    final withSettings = {for (final row in settings) row.pagePublicId};
    decisions.addAll([
      for (final page in listedIds)
        if (!withSettings.contains(page)) SettingsLeft(page),
      for (final row in settings) RowTaken(row),
    ]);
    final live = nextPages.keys.toSet();
    return Taken(
      Shown(
        fence: fence,
        listTaken: started ?? listTaken,
        pagesTaken: {
          for (final MapEntry(:key, :value) in pagesTaken.entries)
            if (listedIds.contains(key)) key: value,
        },
        fresh: fresh.afterList(live),
        list: switch ((list, createdAtOf(strategyRow))) {
          (final owed, _) when !paidBy(owed, started) => owed,
          (
            ReadOwed(namedLife: final named?) ||
                ReadRefused(namedLife: final named?),
            final listedLife,
          )
              when listedLife == null || listedLife < named =>
            list,
          (
            ReadOwed(unlessLife: final unlessLife?, namedLife: null) ||
                ReadRefused(unlessLife: final unlessLife?, namedLife: null),
            final listedLife,
          )
              when listedLife == null || listedLife <= unlessLife =>
            list,
          _ => const ReadThisSession(),
        },
        pageReads: pageReads,
        goneThisSession: {
          for (final page in goneThisSession)
            if (!live.contains(page)) page,
        },
        highest: _raised(highest, {
          const StrategyTarget(): ?versionOfRow(strategyRow),
          for (final page in listed)
            if (page is! TrashedPage)
              PageTarget(page.publicId): ?versionOfRow(page),
          for (final row in settings)
            SettingsTarget(row.pagePublicId): ?versionOfRow(row),
        }),
        strategy: _strategyRow(strategyRow, listed),
        pages: nextPages,
        trashed: nextTrashed,
        tombstones: _removedOn((page) => !listedIds.contains(page), started),
        settings: {
          for (final row in settings)
            row.pagePublicId: _rowOf(row, row.pagePublicId),
        },
        content: {
          for (final MapEntry(:key, :value) in content.entries)
            if (live.contains(key)) key: value,
        },
        rows: {
          for (final MapEntry(:key, :value) in rows.entries)
            if (listedIds.contains(value.page)) key: value,
        },
      ),
      decisions,
    );
  }

  static Map<Target, Version> _raised(
    Map<Target, Version> highest,
    Map<Target, Version> seen,
  ) => {
    ...highest,
    for (final MapEntry(:key, :value) in seen.entries)
      if (highest[key] == null || value > highest[key]!) key: value,
  };

  Shown withGone(String page) =>
      _with(goneThisSession: {...goneThisSession, page});

  Shown touched(Iterable<String> pages, {required bool list}) =>
      _with(fresh: fresh.touched(pages, list: list));

  Shown owingList(ReadStart since) => _with(list: ReadOwed(since: since));

  Shown owingReadsFor(Iterable<Repair> repairs, ReadStart since) {
    var shown = this;
    for (final repair in repairs) {
      if (repair is! NoCopyOnThisDevice && repair is! DamagedOnThisDevice) {
        continue;
      }
      switch (repair.target) {
        case StrategyTarget() || PageTarget() || SettingsTarget():
          if (!isDebt(shown.list)) shown = shown.owingList(since);
        case ElementTarget() || LineupTarget():
          if (!isDebt(shown.pageRead(repair.page))) {
            shown = shown.owingPage(repair.page, since);
          }
      }
    }
    return shown;
  }

  Shown owingListPast(int? life, ReadStart since, {int? named}) => _with(
    list: ReadOwed(unlessLife: life, namedLife: named, since: since),
  );

  Shown owingPage(String page, ReadStart since) => _with(
    pageReads: {
      ...pageReads,
      page: ReadOwed(since: since),
    },
  );

  Shown listRefused(String problem, ReadStart since) => _with(
    list: ReadRefused(
      problem,
      unlessLife: switch (list) {
        ReadOwed(:final unlessLife) ||
        ReadRefused(:final unlessLife) => unlessLife,
        NotReadThisSession() || ReadThisSession() => null,
      },
      namedLife: namedLifeOf(list),
      since: since,
    ),
  );

  Shown pageRefused(String page, String problem, ReadStart since) => _with(
    pageReads: {
      ...pageReads,
      page: ReadRefused(problem, since: since),
    },
  );

  Shown inNewSession() => Shown(
    list: list.inNewSession,
    pageReads: {
      for (final MapEntry(:key, :value) in pageReads.entries)
        key: value.inNewSession,
    },
    highest: highest,
    strategy: strategy,
    pages: pages,
    trashed: trashed,
    settings: settings,
    content: content,
    rows: rows,
  );

  static Taken _checkedTake(String page, Taken Function(bool reuse) take) {
    final taken = take(shownTakesReuse);
    if (shownTakesChecked && take(false) != taken) throw TakesDiffer(page);
    return taken;
  }

  Taken _withPage(
    PageRow pageRow,
    List<Row> found, {
    required bool paid,
    required ReadStart? started,
    required bool reuse,
  }) {
    final page = pageRow.publicId;
    final heldLive = pages[page];
    final heldPage = heldLive ?? trashed[page];
    final pageTaken = replaces(heldPage, pageRow);
    final decisions = <RowDecision>[
      pageTaken ? RowTaken(pageRow) : RowKept(pageRow, KeptBecause.heldIsNewer),
    ];
    final trashedNow = pageTaken
        ? pageRow is TrashedPage
        : heldLive == null && heldPage != null;
    final next = {...rows};
    final nextTombstones = {...tombstones};
    final raised = {...highest};
    final carried = <Target>{};
    final liveNow = <Target, bool>{};
    for (final row in found) {
      final target = switch (row) {
        ElementRow(:final publicId) => ElementTarget(publicId) as Target,
        LineupGroupRow(:final publicId) => LineupTarget(publicId),
        _ => throw StateError('only page content is read with a page'),
      };
      carried.add(target);
      if (tombstones[target]?.keepsOut(row, started) ?? false) {
        decisions.add(RowKept(row, KeptBecause.leftByANewerResult));
        continue;
      }
      final held = rows[target];
      final shown = switch (held) {
        final held? when reuse && held.holdsDigestOf(row, page) => held,
        _ => _digested(row, page),
      };
      if (shown.version case final version?
          when raised[target] == null || version > raised[target]!) {
        raised[target] = version;
      }
      if (!replaces(held, row)) {
        decisions.add(RowKept(row, KeptBecause.heldIsNewer));
        continue;
      }
      decisions.addAll([
        if (held != null && held.page != page)
          ItemLeft(target, page: held.page),
        held == shown ? RowUnchanged(row) : RowTaken(row),
      ]);
      next[target] = shown;
      liveNow[target] = lifeOfRow(row) == Life.live;
      nextTombstones.remove(target);
    }
    for (final MapEntry(:key, :value) in rows.entries) {
      if (value.page != page) continue;
      if (carried.contains(key)) continue;
      next.remove(key);
      decisions.add(ItemLeft(key, page: page));
      if (started != null) {
        nextTombstones[key] = Removed(started, held: value.version);
      }
    }
    decisions.add(UnreadableLeft(page, found));
    final before = content[page] ?? const <SeenPart, String>{};
    final live = <SeenPart, String>{
      for (final MapEntry(:key, :value) in next.entries)
        if (value.page == page)
          if (_partOf(key) case final part?)
            if (liveNow[key] ?? before.containsKey(part)) part: value.digest,
    };
    return Taken(
      _with(
        pagesTaken: {...pagesTaken, page: ?started},
        fresh: fresh.afterPage(page, gone: trashedNow),
        pageReads: {
          ...pageReads,
          page: paid ? const ReadThisSession() : pageRead(page),
        },
        goneThisSession: {...goneThisSession}..remove(page),
        highest: raised,
        pages: switch ((pageTaken, trashedNow)) {
          (true, true) => {...pages}..remove(page),
          (true, false) => {...pages, page: _rowOf(pageRow, pageRow)},
          (false, _) => pages,
        },
        trashed: switch ((pageTaken, trashedNow)) {
          (true, true) => {...trashed, page: _rowOf(pageRow, pageRow)},
          (true, false) => {...trashed}..remove(page),
          (false, _) => trashed,
        },
        tombstones: nextTombstones,
        content: trashedNow
            ? ({...content}..remove(page))
            : {...content, page: live},
        rows: next,
      ),
      decisions,
    );
  }

  static SeenPart? _partOf(Target target) => switch (target) {
    ElementTarget(:final elementPublicId) => SeenElement(elementPublicId),
    LineupTarget(:final lineupPublicId) => SeenLineupGroup(lineupPublicId),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is Shown &&
      other.strategy == strategy &&
      other.fresh == fresh &&
      other.list == list &&
      other.listTaken == listTaken &&
      other.fence == fence &&
      const MapEquality<String, ReadStart>().equals(
        other.pagesTaken,
        pagesTaken,
      ) &&
      const MapEquality<String, ReadState>().equals(
        other.pageReads,
        pageReads,
      ) &&
      const SetEquality<String>().equals(
        other.goneThisSession,
        goneThisSession,
      ) &&
      sameMap(other.pages, pages) &&
      sameMap(other.trashed, trashed) &&
      sameMap(other.tombstones, tombstones) &&
      sameMap(other.settings, settings) &&
      const DeepCollectionEquality().equals(other.content, content) &&
      sameMap(other.rows, rows) &&
      sameMap(other.highest, highest);

  @override
  int get hashCode =>
      Object.hash(strategy, pages.length, content.length, rows.length);
}

bool _outranks(Version? a, Version? b) => switch ((a, b)) {
  (final a?, final b?) => a > b,
  (_?, null) => true,
  (null, _) => false,
};
