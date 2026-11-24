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
  notInStore('the store does not keep this strategy here'),
  tiedPositions('two pages share a position'),
  noPages('the strategy has no pages'),
  damagedRows('the store holds rows this build cannot show'),
  hiveWriteDuringRead('a Hive write began during the read'),
  readFailed('the store read failed');

  const FromHiveBecause(this.words);

  final String words;
}

sealed class PageServedFrom {
  const PageServedFrom();
}

final class ServedFromStore extends PageServedFrom {
  const ServedFromStore();

  @override
  String toString() => 'from the store';
}

final class ServedFromHive extends PageServedFrom {
  const ServedFromHive(this.reason, [this.detail]);

  final FromHiveBecause reason;
  final String? detail;

  @override
  String toString() => 'from Hive: ${reason.words}'
      '${detail == null ? '' : ' ($detail)'}';
}

final class PageLoad {
  const PageLoad({
    required this.kind,
    required this.strategyId,
    required this.pageId,
    required this.served,
    required this.took,
  });

  final PageLoadKind kind;
  final String strategyId;
  final String pageId;
  final PageServedFrom served;
  final Duration took;

  @override
  String toString() => '${kind.name} $strategyId page $pageId $served in '
      '${(took.inMicroseconds / 1000).toStringAsFixed(1)} ms';
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
  final _loads = <PageLoad>[];
  ({String strategyId, bool migrated})? _opening;
  ({LibraryStore store, String strategyId})? _loaded;

  List<PageLoad> get loads => List.unmodifiable(_loads);

  @override
  void opening(String strategyId, {required bool migrated}) =>
      _opening = (strategyId: strategyId, migrated: migrated);

  @override
  LocalPageServed? servedWith(StrategyEditorPageData page) => _served[page];

  @override
  Future<StrategyEditorPageData?> page(
    String strategyId,
    String pageId, {
    required bool migrated,
  }) async {
    final opening = _opening;
    _opening = null;
    final opened = opening?.strategyId == strategyId;
    final clock = Stopwatch()..start();
    final answer = await _answer(
      strategyId,
      pageId,
      migrated: migrated || (opened && opening!.migrated),
    );
    _loads.add(PageLoad(
      kind: opened ? PageLoadKind.open : PageLoadKind.pageSwitch,
      strategyId: strategyId,
      pageId: pageId,
      served: switch (answer) {
        _Page() => const ServedFromStore(),
        _Hive(:final because) => because,
      },
      took: clock.elapsed,
    ));
    switch (answer) {
      case _Page(:final data, :final served):
        _served[data] = served;
        return data;
      case _Hive():
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
    if (_mirror.strategiesNotKnownEqual.contains(strategyId)) {
      return _hive(FromHiveBecause.mayDiffer);
    }
    final begun = _mirror.reads.strategyWritesBegun(strategyId);
    await _unloadOtherThan(store, strategyId);
    final answer = await _read(store, strategyId, pageId);
    if (_mirror.reads.strategyWritesBegun(strategyId) != begun) {
      return _hive(FromHiveBecause.hiveWriteDuringRead);
    }
    if (!identical(_following(), store)) {
      return _hive(FromHiveBecause.mirrorNotFollowing);
    }
    if (_mirror.strategiesNotKnownEqual.contains(strategyId)) {
      return _hive(FromHiveBecause.mayDiffer);
    }
    return answer;
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
    final target = pages.firstWhere(
      (page) => page.publicId == pageId,
      orElse: () => pages.first,
    );
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
