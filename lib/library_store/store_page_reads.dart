import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/local_page_reads.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus_library/icarus_library.dart';

enum PageLoadKind { open, pageSwitch }

enum FromHiveBecause {
  migrationRan('the open migrated the Hive record'),
  mirrorNotFollowing('the mirror is not following'),
  mayDiffer('the store may differ from Hive for this strategy'),
  readsBackDifferently('its rows read back differently from its Hive record'),
  notInStore('the store does not keep this strategy here'),
  tiedPositions('two pages share a position'),
  noPages('the strategy has no pages'),
  damagedRows('the store holds rows this build cannot show'),
  hiveWriteDuringRead('a Hive write began during the read'),
  hiveWriteBeforeApply('a Hive write began after the read, before the apply'),
  pageNotInStore('the store does not hold this page'),
  readFailed('the store read failed');

  const FromHiveBecause(this.words);

  final String words;
}

sealed class PageLoadOutcome {
  const PageLoadOutcome();
}

final class ServedFromStore extends PageLoadOutcome {
  const ServedFromStore();

  @override
  String toString() => 'from the store';
}

final class ServedFromHive extends PageLoadOutcome {
  const ServedFromHive(this.reason, [this.detail]);

  final FromHiveBecause reason;
  final String? detail;

  @override
  String toString() => 'from Hive: ${reason.words}'
      '${detail == null ? '' : ' ($detail)'}';
}

final class GaveWay extends PageLoadOutcome {
  const GaveWay();

  @override
  String toString() =>
      'never shown: it was closed or replaced before its page was applied';
}

final class LoadFailed extends PageLoadOutcome {
  const LoadFailed(this.error);

  final Object error;

  @override
  String toString() => 'failed: $error';
}

final class NoPageToShow extends PageLoadOutcome {
  const NoPageToShow();

  @override
  String toString() => 'no page to show: the strategy has none';
}

final class PageLoad {
  const PageLoad({
    required this.kind,
    required this.strategyId,
    required this.pageId,
    required this.outcome,
    required this.took,
  });

  final PageLoadKind kind;
  final String strategyId;
  final String? pageId;
  final PageLoadOutcome outcome;
  final Duration took;

  @override
  String toString() => '${kind.name} $strategyId page ${pageId ?? '-'} '
      '$outcome, read in ${(took.inMicroseconds / 1000).toStringAsFixed(1)} ms';
}

final class _Load {
  _Load(
    this.attempt,
    this.kind,
    this.strategyId,
    this.pageId,
    this.read,
    this.took,
  );

  final int? attempt;
  final PageLoadKind kind;
  final String strategyId;
  final String pageId;
  final PageLoadOutcome read;
  final Duration took;
}

sealed class _Answer {
  const _Answer();
}

final class _Page extends _Answer {
  const _Page(this.data, this.served);

  final StrategyEditorPageData data;
  final LocalPageServed served;
}

final class _Hive extends _Answer {
  const _Hive(this.because);

  final ServedFromHive because;
}

_Hive _hive(FromHiveBecause reason, [String? detail]) =>
    _Hive(ServedFromHive(reason, detail));

final class StorePageReads implements LocalPageReads {
  StorePageReads(this._mirror);

  final StoreMirror _mirror;
  final _served = Expando<LocalPageServed>('served from the store');
  final _drawnBy = Expando<_Load>('the load that drew a page');
  final _writesBegunAtRead = Expando<int>('Hive writes begun at the read');
  final _loads = <PageLoad>[];
  final _unshown = <_Load>[];
  final _fellBack = <(String, String), _Load>{};
  final _unended =
      <int, ({PageLoadKind kind, String strategyId, String? pageId})>{};
  ({int open, String strategyId, bool migrated})? _opening;
  ({int attempt, String strategyId, String pageId})? _switching;
  ({LibraryStore store, String strategyId})? _loaded;

  List<PageLoad> get loads => List.unmodifiable(_loads);

  var _attempts = 0;
  var _readings = 0;

  @override
  int opening(String strategyId) =>
      _attempt((kind: PageLoadKind.open, strategyId: strategyId, pageId: null));

  @override
  int switching(String strategyId, String pageId) {
    final attempt = _attempt(
      (kind: PageLoadKind.pageSwitch, strategyId: strategyId, pageId: pageId),
    );
    _switching = (attempt: attempt, strategyId: strategyId, pageId: pageId);
    return attempt;
  }

  int _attempt(({PageLoadKind kind, String strategyId, String? pageId}) of) {
    _attempts += 1;
    _unended[_attempts] = of;
    return _attempts;
  }

  @override
  void reading(int open, {required bool migrated}) {
    _readings += 1;
    _gaveWay();
    if (_unended[open]
        case (:final strategyId, kind: PageLoadKind.open, pageId: _)) {
      _opening = (open: open, strategyId: strategyId, migrated: migrated);
    }
  }

  @override
  void openFailed(int open, Object error) => _ends(open, LoadFailed(error));

  @override
  void openEnded(int open) => _ends(open, const GaveWay());

  @override
  void openedWithoutPage(int open) => _ends(open, const NoPageToShow());

  @override
  void switchFailed(int attempt, Object error) =>
      _ends(attempt, LoadFailed(error));

  @override
  void switchEnded(int attempt) => _ends(attempt, const GaveWay());

  @override
  LocalPageServed? servedWith(StrategyEditorPageData page) => _served[page];

  @override
  bool hiveWrittenSinceRead(StrategyEditorPageData page) {
    final begun = _writesBegunAtRead[page];
    final load = _drawnBy[page];
    if (begun == null || load == null) return false;
    return _mirror.reads.strategyWritesBegun(load.strategyId) != begun ||
        (_served[page] != null && _notServed(load.strategyId) != null);
  }

  @override
  StrategyEditorPageData redrawnFromHive(
    StrategyEditorPageData served,
    StrategyEditorPageData hive,
  ) {
    final load = _drawnBy[served];
    _drawnBy[served] = null;
    _served[served] = null;
    if (load == null || !_unshown.remove(load)) return hive;
    final again = _Load(
      load.attempt,
      load.kind,
      load.strategyId,
      load.pageId,
      switch (load.read) {
        ServedFromStore() =>
          const ServedFromHive(FromHiveBecause.hiveWriteBeforeApply),
        final fromHive => fromHive,
      },
      load.took,
    );
    _unshown.add(again);
    _drawnBy[hive] = again;
    return hive;
  }

  @override
  StrategyEditorPageData drawnFromHive(
    String strategyId,
    String pageId,
    StrategyEditorPageData page,
  ) {
    if (_fellBack.remove((strategyId, pageId)) case final load?) {
      _drawnBy[page] = load;
      _writesBegunAtRead[page] = _mirror.reads.strategyWritesBegun(strategyId);
    }
    return page;
  }

  @override
  void applied(StrategyEditorPageData page) {
    final load = _drawnBy[page];
    if (load == null || !_unshown.remove(load)) return;
    _drawnBy[page] = null;
    _ended(load, load.read, shownPageId: page.pageId);
  }

  void _gaveWay() {
    if (_opening case final unread?) _ends(unread.open, const GaveWay());
    _unshown.forEach(_neverShown);
    _unshown.clear();
    _fellBack.clear();
  }

  void _ends(int attempt, PageLoadOutcome outcome) {
    if (_opening?.open == attempt) _opening = null;
    if (_switching?.attempt == attempt) _switching = null;
    final load = _unshown.where((load) => load.attempt == attempt).firstOrNull;
    if (load != null) {
      _unshown.remove(load);
      _ended(load, outcome);
      return;
    }
    final unread = _unended.remove(attempt);
    if (unread == null) return;
    _loads.add(PageLoad(
      kind: unread.kind,
      strategyId: unread.strategyId,
      pageId: unread.pageId,
      outcome: outcome,
      took: Duration.zero,
    ));
  }

  void _neverShown(_Load load) => _ended(load, const GaveWay());

  void _ended(_Load load, PageLoadOutcome outcome, {String? shownPageId}) {
    if (load.attempt case final attempt?
        when _unended.remove(attempt) == null) {
      return;
    }
    _loads.add(PageLoad(
      kind: load.kind,
      strategyId: load.strategyId,
      pageId: shownPageId ?? load.pageId,
      outcome: outcome,
      took: load.took,
    ));
  }

  @override
  Future<StrategyEditorPageData?> page(
    String strategyId,
    String pageId, {
    required bool migrated,
  }) async {
    final opening = _opening;
    _opening = null;
    final opened = opening?.strategyId == strategyId;
    final switching = _switching;
    _switching = null;
    final switched = !opened &&
        switching?.strategyId == strategyId &&
        switching?.pageId == pageId;
    final readings = _readings;
    final begun = _mirror.reads.strategyWritesBegun(strategyId);
    final clock = Stopwatch()..start();
    final answer = await _answer(
      strategyId,
      pageId,
      migrated: migrated || (opened && opening!.migrated),
    );
    final load = _Load(
      opened
          ? opening!.open
          : switched
              ? switching!.attempt
              : null,
      opened ? PageLoadKind.open : PageLoadKind.pageSwitch,
      strategyId,
      pageId,
      switch (answer) {
        _Page() => const ServedFromStore(),
        _Hive(:final because) => because,
      },
      clock.elapsed,
    );
    if (readings != _readings) {
      _neverShown(load);
      return null;
    }
    _unshown.add(load);
    switch (answer) {
      case _Page(:final data, :final served):
        _served[data] = served;
        _drawnBy[data] = load;
        _writesBegunAtRead[data] = begun;
        return data;
      case _Hive():
        _fellBack[(strategyId, pageId)] = load;
        return null;
    }
  }

  LibraryStore? _following() => switch (_mirror.phase) {
        MirrorFollowing(:final store) when store.isOpen => store,
        _ => null,
      };

  Future<_Answer> _answer(
    String strategyId,
    String pageId, {
    required bool migrated,
  }) async {
    if (migrated) return _hive(FromHiveBecause.migrationRan);
    final store = _following();
    if (store == null) return _hive(FromHiveBecause.mirrorNotFollowing);
    if (_notServed(strategyId) case final because?) return because;
    final begun = _mirror.reads.strategyWritesBegun(strategyId);
    await _unloadOtherThan(store, strategyId);
    final answer = await _read(store, strategyId, pageId);
    if (_mirror.reads.strategyWritesBegun(strategyId) != begun) {
      return _hive(FromHiveBecause.hiveWriteDuringRead);
    }
    if (!identical(_following(), store)) {
      return _hive(FromHiveBecause.mirrorNotFollowing);
    }
    if (_notServed(strategyId) case final because?) return because;
    return answer;
  }

  _Hive? _notServed(String strategyId) {
    if (_mirror.strategiesNotKnownEqual.contains(strategyId)) {
      return _hive(FromHiveBecause.mayDiffer);
    }
    if (_mirror.strategiesReadingBackDifferently[strategyId]
        case final words?) {
      return _hive(FromHiveBecause.readsBackDifferently, words);
    }
    return null;
  }

  Future<void> _unloadOtherThan(LibraryStore store, String strategyId) async {
    final loaded = _loaded;
    _loaded = (store: store, strategyId: strategyId);
    if (loaded == null ||
        (identical(loaded.store, store) && loaded.strategyId == strategyId)) {
      return;
    }
    if (loaded.store.isOpen) await loaded.store.unload(loaded.strategyId);
  }

  Future<_Answer> _read(
    LibraryStore store,
    String strategyId,
    String pageId,
  ) async {
    final StrategyContent content;
    switch (await store.readStrategy(strategyId)) {
      case Found(:final value):
        content = value;
      case NotFound():
        return _hive(FromHiveBecause.notInStore);
      case NotRead(:final failure):
        return _hive(FromHiveBecause.readFailed, '$failure');
      case InUnreadableStrategy(:final listing):
        return _hive(FromHiveBecause.damagedRows, 'header ${listing.ref}');
    }
    if (content.sync is! LocalStrategy) {
      return _hive(FromHiveBecause.notInStore, 'kept for the cloud');
    }
    final ReadableStrategy header;
    switch (content.strategy) {
      case final ReadableStrategy readable:
        header = readable;
      case UnreadableStrategy(:final problem):
        return _hive(FromHiveBecause.damagedRows, 'header: $problem');
    }
    if (content.unplaced.isNotEmpty || content.foreignNames.isNotEmpty) {
      return _hive(FromHiveBecause.damagedRows, 'unplaced or foreign rows');
    }
    final pages = <LivePage>[];
    for (final page in content.pages) {
      switch (page) {
        case final LivePage live:
          pages.add(live);
        case TrashedPage() || UnreadablePage():
          return _hive(FromHiveBecause.damagedRows, 'page ${page.publicId}');
      }
    }
    if (pages.isEmpty) return _hive(FromHiveBecause.noPages);
    pages.sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    for (var i = 1; i < pages.length; i++) {
      if (pages[i].sortIndex == pages[i - 1].sortIndex) {
        return _hive(FromHiveBecause.tiedPositions);
      }
    }
    final target = pages.where((page) => page.publicId == pageId).firstOrNull;
    if (target == null) return _hive(FromHiveBecause.pageNotInStore);
    final PageContent onPage;
    switch (await store.readPage(strategyId, target.publicId)) {
      case Found(:final value):
        onPage = value;
      case NotFound():
        return _hive(FromHiveBecause.damagedRows, 'page ${target.publicId}');
      case NotRead(:final failure):
        return _hive(FromHiveBecause.readFailed, '$failure');
      case InUnreadableStrategy(:final listing):
        return _hive(FromHiveBecause.damagedRows, 'header ${listing.ref}');
    }
    final PageSettingsRow settings;
    switch (onPage.settings) {
      case SettingsStored(:final row):
        settings = row;
      case NoSettingsStored():
        return _hive(FromHiveBecause.damagedRows, 'no settings row');
    }
    if (onPage.unplaced.isNotEmpty ||
        onPage.unknownKinds.isNotEmpty ||
        onPage.foreignNames.isNotEmpty) {
      return _hive(FromHiveBecause.damagedRows, 'rows on the page');
    }
    final made = strategyFromRows(StrategyRowSet(
      strategy: header,
      pages: [target],
      settings: [settings],
      elements: onPage.elements,
      lineupGroups: onPage.lineupGroups,
    ));
    final StrategyData strategy;
    switch (made) {
      case StrategyDataMade(
            strategy: final drawn,
            :final unreadable,
            :final notInStrategy,
          )
          when unreadable.isEmpty && notInStrategy.isEmpty:
        strategy = drawn;
      case StrategyDataMade():
        return _hive(
            FromHiveBecause.damagedRows, 'rows this build cannot draw');
      case StrategyDataRefused(:final problems):
        return _hive(FromHiveBecause.damagedRows, problems.join('; '));
    }
    final page = strategy.pages.single;
    return _Page(
      StrategyEditorPageData(
        pageId: page.id,
        pageName: page.name,
        isAttack: page.isAttack,
        map: strategy.mapData,
        settings: page.settings,
        agents: page.agentData,
        abilities: page.abilityData,
        drawings: page.drawingData,
        texts: page.textData,
        images: page.imageData,
        utilities: page.utilityData,
        lineUpGraph: page.lineUpGraph,
        unshown: UnshownCloudContent.none,
      ),
      LocalPageServed(
        pageIds: [for (final page in pages) page.publicId],
        themeProfileId: strategy.themeProfileId ??
            MapThemeProfilesProvider.immutableDefaultProfileId,
        themeOverridePalette: strategy.themeOverridePalette,
      ),
    );
  }
}
