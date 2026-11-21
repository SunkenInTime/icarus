import '../json.dart';
import '../rows.dart';
import '../wire.dart' show isSafeWhole;
import 'events.dart';
import 'op_facts.dart';
import 'pending.dart';

const evidenceRowVersion = 1;

sealed class ReadNeed {
  const ReadNeed();
}

final class PageListNeed extends ReadNeed {
  const PageListNeed();

  @override
  bool operator ==(Object other) => other is PageListNeed;

  @override
  int get hashCode => (PageListNeed).hashCode;

  @override
  String toString() => 'the page list';
}

final class PageNeed extends ReadNeed {
  const PageNeed(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is PageNeed && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(PageNeed, pagePublicId);

  @override
  String toString() => 'page $pagePublicId';
}

sealed class Claim {
  const Claim(this.after);

  final int after;

  ReadNeed get need;
}

int _laterOf(int a, int b) => a > b ? a : b;

ReadNeed _rowNeed(String? page) => switch (page) {
  final page? => PageNeed(page),
  null => const PageListNeed(),
};

final class RowAsAuthored extends Claim {
  const RowAsAuthored(
    this.target,
    this.authored, {
    required this.onPage,
    required int after,
  }) : super(after);

  final Target target;
  final Authored authored;
  final String? onPage;

  @override
  ReadNeed get need => switch (target) {
    StrategyTarget() ||
    PageTarget() ||
    SettingsTarget() => const PageListNeed(),
    ElementTarget() || LineupTarget() => _rowNeed(onPage),
  };

  @override
  bool operator ==(Object other) =>
      other is RowAsAuthored &&
      other.target == target &&
      other.authored == authored &&
      other.onPage == onPage &&
      other.after == after;

  @override
  int get hashCode => Object.hash(RowAsAuthored, target, onPage, after);

  @override
  String toString() => '$target as authored after read $after';
}

final class RowStillOn extends Claim {
  const RowStillOn(
    this.target, {
    required this.page,
    required this.existed,
    required int after,
  }) : super(after);

  final Target target;
  final String page;
  final bool existed;

  @override
  ReadNeed get need => PageNeed(page);

  @override
  bool operator ==(Object other) =>
      other is RowStillOn &&
      other.target == target &&
      other.page == page &&
      other.existed == existed &&
      other.after == after;

  @override
  int get hashCode => Object.hash(RowStillOn, target, page, existed, after);

  @override
  String toString() => '$target still on $page after read $after';
}

final class RowShown extends Claim {
  const RowShown(
    this.target, {
    required this.revision,
    required this.lookIn,
    required int after,
  }) : super(after);

  final Target target;
  final int revision;
  final String? lookIn;

  @override
  ReadNeed get need => switch (target) {
    StrategyTarget() ||
    PageTarget() ||
    SettingsTarget() => const PageListNeed(),
    ElementTarget() || LineupTarget() => _rowNeed(lookIn),
  };

  @override
  bool operator ==(Object other) =>
      other is RowShown &&
      other.target == target &&
      other.revision == revision &&
      other.lookIn == lookIn &&
      other.after == after;

  @override
  int get hashCode => Object.hash(RowShown, target, revision, lookIn, after);

  @override
  String toString() => '$target shown at $revision after read $after';
}

final class RowShownOn extends Claim {
  const RowShownOn(
    this.target, {
    required this.revision,
    required this.page,
    required int after,
  }) : super(after);

  final Target target;
  final int revision;
  final String page;

  @override
  ReadNeed get need => PageNeed(page);

  @override
  bool operator ==(Object other) =>
      other is RowShownOn &&
      other.target == target &&
      other.revision == revision &&
      other.page == page &&
      other.after == after;

  @override
  int get hashCode => Object.hash(RowShownOn, target, revision, page, after);

  @override
  String toString() => '$target shown at $revision on $page after read $after';
}

final class RowIsGone extends Claim {
  const RowIsGone(this.target, {required this.onPage, required int after})
    : super(after);

  final Target target;
  final String? onPage;

  @override
  ReadNeed get need => _rowNeed(onPage);

  @override
  bool operator ==(Object other) =>
      other is RowIsGone &&
      other.target == target &&
      other.onPage == onPage &&
      other.after == after;

  @override
  int get hashCode => Object.hash(RowIsGone, target, onPage, after);

  @override
  String toString() => '$target gone after read $after';
}

final class RowPayloadVersion extends Claim {
  const RowPayloadVersion(
    this.target, {
    required this.payloadVersion,
    required int after,
  }) : super(after);

  final Target target;
  final int payloadVersion;

  @override
  ReadNeed get need => const PageListNeed();

  @override
  bool operator ==(Object other) =>
      other is RowPayloadVersion &&
      other.target == target &&
      other.payloadVersion == payloadVersion &&
      other.after == after;

  @override
  int get hashCode =>
      Object.hash(RowPayloadVersion, target, payloadVersion, after);

  @override
  String toString() =>
      '$target at payload version $payloadVersion after read $after';
}

final class RowRevision extends Claim {
  const RowRevision(this.target, {required int after}) : super(after);

  final Target target;

  @override
  ReadNeed get need => const PageListNeed();

  @override
  bool operator ==(Object other) =>
      other is RowRevision && other.target == target && other.after == after;

  @override
  int get hashCode => Object.hash(RowRevision, target, after);

  @override
  String toString() => 'the revision of $target after read $after';
}

final class PageIsGone extends Claim {
  const PageIsGone(this.page, {required int after}) : super(after);

  final String page;

  @override
  ReadNeed get need => PageNeed(page);

  @override
  bool operator ==(Object other) =>
      other is PageIsGone && other.page == page && other.after == after;

  @override
  int get hashCode => Object.hash(PageIsGone, page, after);

  @override
  String toString() => 'page $page gone after read $after';
}

final class PageIsLive extends Claim {
  const PageIsLive(this.page, {required int after}) : super(after);

  final String page;

  @override
  ReadNeed get need => const PageListNeed();

  @override
  bool operator ==(Object other) =>
      other is PageIsLive && other.page == page && other.after == after;

  @override
  int get hashCode => Object.hash(PageIsLive, page, after);

  @override
  String toString() => 'page $page live after read $after';
}

final class PageAsSeen extends Claim {
  const PageAsSeen(this.page, this.seen, {required int after}) : super(after);

  final String page;
  final SeenPage seen;

  @override
  ReadNeed get need => PageNeed(page);

  @override
  bool operator ==(Object other) =>
      other is PageAsSeen &&
      other.page == page &&
      other.seen == seen &&
      other.after == after;

  @override
  int get hashCode => Object.hash(PageAsSeen, page, after);

  @override
  String toString() => 'page $page as seen after read $after';
}

final class PageContentRead extends Claim {
  const PageContentRead(this.page, {required int after}) : super(after);

  final String page;

  @override
  ReadNeed get need => PageNeed(page);

  @override
  bool operator ==(Object other) =>
      other is PageContentRead && other.page == page && other.after == after;

  @override
  int get hashCode => Object.hash(PageContentRead, page, after);

  @override
  String toString() => 'the content of page $page after read $after';
}

sealed class Proof {
  const Proof();
}

final class Proven extends Proof {
  const Proven();
}

final class ProvenAt extends Proof {
  const ProvenAt(this.revision);

  final int revision;
}

final class Disproven extends Proof {
  const Disproven();
}

final class Unproven extends Proof {
  const Unproven();
}

sealed class BaseChange {
  const BaseChange();
}

final class RowPut extends BaseChange {
  const RowPut(this.row);

  final Row row;
}

final class RowDropped extends BaseChange {
  const RowDropped(this.target, this.page);

  final Target target;
  final String page;
}

final class PageDropped extends BaseChange {
  const PageDropped(this.page);

  final String page;
}

final class Taken {
  Taken(this.evidence, List<BaseChange> changes)
    : changes = List.unmodifiable(changes);

  final Evidence evidence;
  final List<BaseChange> changes;
}

sealed class EvidenceReading {
  const EvidenceReading();
}

final class EvidenceRead extends EvidenceReading {
  const EvidenceRead(this.evidence);

  final Evidence evidence;
}

final class EvidenceUnreadable extends EvidenceReading {
  const EvidenceUnreadable(this.name, this.problem);

  final String name;
  final String problem;
}

sealed class _Sighting {
  const _Sighting();
}

final class _Seen extends _Sighting {
  const _Seen(this.revision, this.digest, this.life, this.payloadVersion);

  final int revision;
  final String digest;
  final Life life;
  final int? payloadVersion;

  @override
  bool operator ==(Object other) =>
      other is _Seen &&
      other.revision == revision &&
      other.digest == digest &&
      other.life == life &&
      other.payloadVersion == payloadVersion;

  @override
  int get hashCode => Object.hash(revision, digest, life, payloadVersion);
}

final class _Unreadable extends _Sighting {
  const _Unreadable();

  @override
  bool operator ==(Object other) => other is _Unreadable;

  @override
  int get hashCode => (_Unreadable).hashCode;
}

final class _Absent extends _Sighting {
  const _Absent();
}

final class _Said {
  const _Said(this.read, this.page, this.sighting);

  final int read;
  final String page;
  final _Sighting sighting;

  @override
  bool operator ==(Object other) =>
      other is _Said &&
      other.read == read &&
      other.page == page &&
      other.sighting == sighting;

  @override
  int get hashCode => Object.hash(read, page, sighting);
}

final class _PageSaid {
  const _PageSaid(this.read, this.sighting, this.since);

  final int read;
  final _Sighting sighting;
  final int since;

  bool get live => sighting is! _Absent;

  @override
  bool operator ==(Object other) =>
      other is _PageSaid &&
      other.read == read &&
      other.sighting == sighting &&
      other.since == since;

  @override
  int get hashCode => Object.hash(read, sighting, since);
}

final class _ContentSaid {
  _ContentSaid(this.read, Map<SeenPart, String> digests, Set<Target> present)
    : digests = Map.unmodifiable(digests),
      present = Set.unmodifiable(present);

  final int read;
  final Map<SeenPart, String> digests;
  final Set<Target> present;

  @override
  bool operator ==(Object other) =>
      other is _ContentSaid &&
      other.read == read &&
      sameMap(other.digests, digests) &&
      sameSet(other.present, present);

  @override
  int get hashCode => Object.hash(read, digests.length, present.length);
}

final class _ReadSaid {
  const _ReadSaid(this.read, this.sighting);

  final int read;
  final _Sighting sighting;

  @override
  bool operator ==(Object other) =>
      other is _ReadSaid && other.read == read && other.sighting == sighting;

  @override
  int get hashCode => Object.hash(read, sighting);
}

_Sighting _sightingOf(Row row, {String? digest}) =>
    switch (revisionOfRow(row)) {
      final revision? => _Seen(
        revision,
        digest ?? rowDigest(row),
        lifeOfRow(row),
        switch (row) {
          ReadableElementRow(:final payload) => payload.payloadVersion,
          ReadableLineupGroupRow(:final payload) => payload.payloadVersion,
          _ => null,
        },
      ),
      null => const _Unreadable(),
    };

Target _targetOfRow(Row row) => switch (row) {
  ElementRow(:final publicId) => ElementTarget(publicId),
  LineupGroupRow(:final publicId) => LineupTarget(publicId),
  _ => throw StateError('only page content has a row target'),
};

final class Evidence {
  Evidence._({
    required Map<Target, _Said> rows,
    required Map<String, _PageSaid> pages,
    required Map<String, _ReadSaid> settings,
    required Map<String, _ContentSaid> content,
    required _ReadSaid? strategy,
    required int headers,
  }) : _rows = rows,
       _pages = pages,
       _settings = settings,
       _content = content,
       _strategy = strategy,
       _headers = headers;

  static final none = Evidence._(
    rows: const {},
    pages: const {},
    settings: const {},
    content: const {},
    strategy: null,
    headers: 0,
  );

  final Map<Target, _Said> _rows;
  final Map<String, _PageSaid> _pages;
  final Map<String, _ReadSaid> _settings;
  final Map<String, _ContentSaid> _content;
  final _ReadSaid? _strategy;
  final int _headers;
  late final Map<String, Set<Target>> _onPage = () {
    final index = <String, Set<Target>>{};
    for (final MapEntry(key: target, value: said) in _rows.entries) {
      (index[said.page] ??= {}).add(target);
    }
    return index;
  }();

  late final int lastRead = [
    for (final said in _rows.values) said.read,
    for (final said in _pages.values) said.read,
    for (final said in _settings.values) said.read,
    for (final said in _content.values) said.read,
    ?_strategy?.read,
    _headers,
  ].fold(0, (most, read) => read > most ? read : most);

  _PageSaid? _page(String page) =>
      _pages[page] ??
      (_headers > 0 ? _PageSaid(_headers, const _Absent(), 0) : null);

  int _goneAt(String page) => switch (_page(page)) {
    _PageSaid(sighting: _Absent(), :final read) => read,
    _PageSaid(:final since) => since,
    null => 0,
  };

  bool _counts(String page, _ContentSaid content) => switch (_page(page)) {
    _PageSaid(sighting: _Absent()) => false,
    _PageSaid(:final since) => content.read > since,
    null => true,
  };

  _Said? _row(Target target, String? lookIn) {
    final said = _rows[target];
    if (said == null) {
      if (lookIn == null) return null;
      final content = _content[lookIn];
      final fromContent =
          content != null &&
              _counts(lookIn, content) &&
              !content.present.contains(target)
          ? content.read
          : 0;
      final gone = _goneAt(lookIn);
      final absent = fromContent > gone ? fromContent : gone;
      return absent > 0 ? _Said(absent, lookIn, const _Absent()) : null;
    }
    final page = said.page;
    var absent = 0;
    if (_content[page] case final content?
        when content.read > said.read && !content.present.contains(target)) {
      absent = content.read;
    }
    final gone = _goneAt(page);
    if (gone > said.read && gone > absent) absent = gone;
    return absent > 0 ? _Said(absent, page, const _Absent()) : said;
  }

  _Said? _visibleRow(Target target) => switch (_row(target, null)) {
    final said? when said.sighting is! _Absent && _pageShown(said.page) => said,
    _ => null,
  };

  bool _pageShown(String page) => _page(page)?.live ?? false;

  _Said? _anyRow(Target target, String? lookIn) => switch (target) {
    StrategyTarget() => switch (_strategy) {
      final said? => _Said(said.read, '', said.sighting),
      null => null,
    },
    PageTarget(:final pagePublicId) => switch (_page(pagePublicId)) {
      final said? => _Said(said.read, pagePublicId, said.sighting),
      null => null,
    },
    SettingsTarget(:final pagePublicId) => switch ((
      _page(pagePublicId),
      _settings[pagePublicId],
    )) {
      (_PageSaid(sighting: _Absent(), :final read), _) => _Said(
        read,
        pagePublicId,
        const _Absent(),
      ),
      (_, final said?) => _Said(said.read, pagePublicId, said.sighting),
      _ => null,
    },
    ElementTarget() || LineupTarget() => _row(target, lookIn),
  };

  Taken take(ArrivedBase arrived, int read) {
    final edit = _EvidenceEdit(this);
    final rowsByTarget = <Target, Row>{};
    final pageRows = <String, PageRow>{};
    final settingsRows = <String, PageSettingsRow>{};
    final pages = <String>{};
    switch (arrived) {
      case HeaderRead(:final strategy, :final pages, :final settings):
        edit.strategy(
          read,
          _sightingOf(strategy, digest: strategyDigest(strategy, pages)),
        );
        final listed = <String>{};
        for (final page in pages) {
          listed.add(page.publicId);
          pageRows[page.publicId] = page;
          edit.page(read, page.publicId, _sightingOf(page));
        }
        for (final row in settings) {
          settingsRows[row.pagePublicId] = row;
          edit.settings(read, row.pagePublicId, _sightingOf(row));
        }
        for (final page in {..._pages.keys, ..._onPage.keys}) {
          if (!listed.contains(page)) {
            edit.page(read, page, const _Absent());
          }
        }
        edit.header(read);
      case PageRead(:final page, :final elements, :final lineupGroups):
        final id = page.publicId;
        pageRows[id] = page;
        edit.page(read, id, _sightingOf(page));
        final found = [...elements, ...lineupGroups];
        edit.content(
          read,
          id,
          _ContentSaid(read, liveContentOn(found, id), {
            for (final row in found) _targetOfRow(row),
          }),
        );
        for (final row in found) {
          final target = _targetOfRow(row);
          rowsByTarget[target] = row;
          edit.row(read, target, _Said(read, id, _sightingOf(row)));
        }
        pages.add(id);
      case PageGone(:final pagePublicId):
        edit.page(read, pagePublicId, const _Absent());
        pages.add(pagePublicId);
      case StrategyGone():
        break;
    }
    final next = edit.build();
    return Taken(
      next,
      _changesBetween(
        next,
        read,
        pages,
        rowsByTarget,
        pageRows,
        settingsRows,
        arrived,
      ),
    );
  }

  List<BaseChange> _changesBetween(
    Evidence next,
    int read,
    Set<String> touched,
    Map<Target, Row> rows,
    Map<String, PageRow> pageRows,
    Map<String, PageSettingsRow> settingsRows,
    ArrivedBase arrived,
  ) {
    final changes = <BaseChange>[];
    if (arrived case HeaderRead(
      :final strategy,
    ) when next._strategy?.read == read && _strategy?.read != read) {
      changes.add(RowPut(strategy));
    }
    final pages = {
      ...touched,
      ...pageRows.keys,
      if (arrived is HeaderRead) ...{..._pages.keys, ..._onPage.keys},
    };
    for (final page in pages) {
      final before = _pageShown(page);
      final after = next._pageShown(page);
      if (before && !after) changes.add(PageDropped(page));
      if (after &&
          next._pages[page]?.read == read &&
          (!before || _pages[page]?.read != read)) {
        if (pageRows[page] case final row?) changes.add(RowPut(row));
      }
      if (after &&
          next._settings[page]?.read == read &&
          _settings[page]?.read != read) {
        if (settingsRows[page] case final row?) changes.add(RowPut(row));
      }
    }
    final targets = {
      ...rows.keys,
      for (final page in pages) ...?_onPage[page],
      for (final page in pages) ...?next._onPage[page],
    };
    for (final target in targets) {
      final before = _visibleRow(target);
      final after = next._visibleRow(target);
      if (after != null && after != before) {
        if (before != null && before.page != after.page) {
          changes.add(RowDropped(target, before.page));
        }
        if (rows[target] case final row?) changes.add(RowPut(row));
      } else if (after == null && before != null) {
        changes.add(RowDropped(target, before.page));
      }
    }
    return changes;
  }

  Proof proves(Claim claim) {
    final after = claim.after;
    switch (claim) {
      case RowAsAuthored(:final target, :final authored, :final onPage):
        final said = _anyRow(target, onPage);
        if (said == null || said.read <= after) return const Unproven();
        return switch ((authored, said.sighting)) {
          (AuthoredUnreadable(), _) => const Disproven(),
          (
            AuthoredRow(:final digest),
            _Seen(digest: final seen, :final revision),
          ) =>
            seen == digest ? ProvenAt(revision) : const Disproven(),
          (AuthoredRow(), _Unreadable() || _Absent()) => const Disproven(),
          (AuthoredNoRow(), _Absent()) => const Proven(),
          (AuthoredNoRow(), _Seen(life: Life.gone, :final revision)) =>
            ProvenAt(revision),
          (AuthoredNoRow(), _Seen() || _Unreadable()) => const Disproven(),
        };
      case RowStillOn(:final target, :final page, :final existed):
        final said = _row(target, page);
        if (said == null || said.read <= after) return const Unproven();
        return switch (said.sighting) {
          _Absent() => existed ? const Disproven() : const Proven(),
          _Seen() || _Unreadable() =>
            said.page == page ? const Proven() : const Disproven(),
        };
      case RowShown(:final target, :final revision, :final lookIn):
        final said = _anyRow(target, lookIn);
        if (said == null) return const Unproven();
        return switch (said.sighting) {
          _Seen(revision: final at) when at >= revision => const Proven(),
          _ when said.read > after => const Proven(),
          _ => const Unproven(),
        };
      case RowShownOn(:final target, :final revision, :final page):
        return switch (_row(target, null)) {
          _Said(
            sighting: _Seen(revision: final at),
            page: final on,
            :final read,
          )
              when on == page && (at >= revision || read > after) =>
            const Proven(),
          _ => const Unproven(),
        };
      case RowIsGone(:final target, :final onPage):
        final said = _row(target, onPage);
        if (said == null || said.read <= after) return const Unproven();
        return switch (said.sighting) {
          _Absent() || _Seen(life: Life.gone) => const Proven(),
          _Seen() || _Unreadable() => const Disproven(),
        };
      case RowPayloadVersion(:final target, :final payloadVersion):
        return switch (_rows[target]) {
          _Said(:final read) when read <= after => const Unproven(),
          _Said(sighting: _Seen(payloadVersion: final seen?)) =>
            seen == payloadVersion ? const Proven() : const Disproven(),
          _ => const Unproven(),
        };
      case RowRevision(:final target):
        final said = switch (target) {
          ElementTarget() || LineupTarget() => _rows[target],
          _ => _anyRow(target, null),
        };
        if (said == null || said.read <= after) return const Unproven();
        return switch (said.sighting) {
          _Seen(:final revision) => ProvenAt(revision),
          _Unreadable() || _Absent() => const Unproven(),
        };
      case PageIsGone(:final page):
        return switch (_page(page)) {
          _PageSaid(:final read) when read <= after => const Unproven(),
          _PageSaid(sighting: _Absent() || _Seen(life: Life.gone)) =>
            const Proven(),
          _PageSaid() => const Disproven(),
          null => const Unproven(),
        };
      case PageIsLive(:final page):
        return switch (_page(page)) {
          _PageSaid(:final read) when read <= after => const Unproven(),
          _PageSaid(sighting: _Absent() || _Seen(life: Life.gone)) =>
            const Disproven(),
          _PageSaid() => const Proven(),
          null => const Unproven(),
        };
      case PageAsSeen(:final page, :final seen):
        final existence = _page(page);
        final content = _content[page];
        final counted = content != null && _counts(page, content);
        final newest = _laterOf(
          existence?.read ?? 0,
          counted ? content.read : 0,
        );
        if (newest <= after) return const Unproven();
        switch ((existence, seen.content)) {
          case (
                _PageSaid(sighting: final sighting) && final said,
                ContentSeen(:final digests),
              )
              when said.live:
            if (!counted) return const Unproven();
            final current = {
              ...content.digests,
              if (_settings[page]?.sighting case _Seen(:final digest))
                const SeenSettings(): digest,
            };
            final pageDigest = switch (sighting) {
              _Seen(:final digest) => digest,
              _Unreadable() || _Absent() => null,
            };
            return sameMap(current, digests) && pageDigest == seen.pageDigest
                ? const Proven()
                : const Disproven();
          case _:
            return const Disproven();
        }
      case PageContentRead(:final page):
        final content = _content[page];
        if (content == null ||
            content.read <= after ||
            !_counts(page, content)) {
          return const Unproven();
        }
        return const Proven();
    }
  }

  Map<String?, String> groupTexts() {
    final groups = <String?, Map<String, Object?>>{};
    Map<String, Object?> groupOf(String? page) =>
        groups[page] ??= {'version': evidenceRowVersion, 'page': ?page};
    if (_strategy case final said?) {
      groupOf(null)['strategy'] = {
        'read': said.read,
        ..._sightingJson(said.sighting),
      };
    }
    if (_headers > 0) groupOf(null)['headers'] = _headers;
    for (final MapEntry(key: page, value: said) in _pages.entries) {
      groupOf(page)['existence'] = {
        'read': said.read,
        'since': said.since,
        ..._sightingJson(said.sighting),
      };
    }
    for (final MapEntry(key: page, value: said) in _settings.entries) {
      groupOf(page)['settings'] = {
        'read': said.read,
        ..._sightingJson(said.sighting),
      };
    }
    for (final MapEntry(key: page, value: said) in _content.entries) {
      groupOf(page)['content'] = {
        'read': said.read,
        'digests': [
          for (final MapEntry(:key, :value) in said.digests.entries)
            ['$key', value],
        ]..sort((a, b) => a[0].compareTo(b[0])),
        'present': [for (final target in said.present) _targetJson(target)]
          ..sort((a, b) => '$a'.compareTo('$b')),
      };
    }
    final rowsByPage = <String, List<Object?>>{};
    for (final MapEntry(key: target, value: said) in _rows.entries) {
      (rowsByPage[said.page] ??= []).add({
        'target': _targetJson(target),
        'read': said.read,
        ..._sightingJson(said.sighting),
      });
    }
    for (final MapEntry(key: page, value: rows) in rowsByPage.entries) {
      groupOf(page)['rows'] = rows..sort((a, b) => '$a'.compareTo('$b'));
    }
    return {
      for (final MapEntry(key: page, value: json) in groups.entries)
        page: canonicalJson(json),
    };
  }

  static EvidenceReading fromGroupTexts(
    Map<String, String> byName,
    String Function(String? page) nameOf,
  ) {
    final read = _GroupReader(nameOf);
    for (final MapEntry(key: name, value: text) in byName.entries) {
      if (read.group(name, text) case final problem?) {
        return EvidenceUnreadable(name, problem);
      }
    }
    return EvidenceRead(read.build());
  }

  static bool readsBack(String? page, String text, String name) =>
      switch (fromGroupTexts({name: text}, (_) => name)) {
        EvidenceRead(:final evidence) => evidence.groupTexts()[page] == text,
        EvidenceUnreadable() => false,
      };

  @override
  bool operator ==(Object other) =>
      other is Evidence &&
      sameMap(other._rows, _rows) &&
      sameMap(other._pages, _pages) &&
      sameMap(other._settings, _settings) &&
      sameMap(other._content, _content) &&
      other._strategy == _strategy &&
      other._headers == _headers;

  @override
  int get hashCode =>
      Object.hash(_rows.length, _pages.length, _content.length, _headers);
}

final class _EvidenceEdit {
  _EvidenceEdit(this._from)
    : _strategy = _from._strategy,
      _headers = _from._headers;

  final Evidence _from;
  Map<Target, _Said>? _rows;
  Map<String, _PageSaid>? _pages;
  Map<String, _ReadSaid>? _settings;
  Map<String, _ContentSaid>? _content;
  _ReadSaid? _strategy;
  int _headers;

  void strategy(int read, _Sighting sighting) {
    if ((_strategy?.read ?? 0) < read) _strategy = _ReadSaid(read, sighting);
  }

  void header(int read) {
    if (read > _headers) _headers = read;
  }

  void settings(int read, String page, _Sighting sighting) {
    final settings = _settings ??= {..._from._settings};
    if ((settings[page]?.read ?? 0) < read) {
      settings[page] = _ReadSaid(read, sighting);
    }
  }

  void page(int read, String page, _Sighting sighting) {
    final pages = _pages ??= {..._from._pages};
    if (!pages.containsKey(page) && _from._headers > 0) {
      pages[page] = _PageSaid(_from._headers, const _Absent(), 0);
    }
    pages[page] = switch (pages[page]) {
      null => _PageSaid(read, sighting, 0),
      final now when read > now.read => _PageSaid(read, sighting, switch ((
        sighting,
        now.sighting,
      )) {
        (_Absent(), _) => 0,
        (_, _Absent()) => now.read,
        _ => now.since,
      }),
      final now when sighting is _Absent && now.live && read > now.since =>
        _PageSaid(now.read, now.sighting, read),
      final now => now,
    };
  }

  void content(int read, String page, _ContentSaid said) {
    final content = _content ??= {..._from._content};
    if ((content[page]?.read ?? 0) < read) content[page] = said;
  }

  void row(int read, Target target, _Said said) {
    final rows = _rows ??= {..._from._rows};
    if ((rows[target]?.read ?? 0) < read) rows[target] = said;
  }

  Evidence build() => Evidence._(
    rows: _rows ?? _from._rows,
    pages: _pages ?? _from._pages,
    settings: _settings ?? _from._settings,
    content: _content ?? _from._content,
    strategy: _strategy,
    headers: _headers,
  );
}

Object? _targetJson(Target target) => switch (target) {
  StrategyTarget() => ['strategy'],
  PageTarget(:final pagePublicId) => ['page', pagePublicId],
  SettingsTarget(:final pagePublicId) => ['settings', pagePublicId],
  ElementTarget(:final elementPublicId) => ['element', elementPublicId],
  LineupTarget(:final lineupPublicId) => ['lineup', lineupPublicId],
};

Target? _targetFrom(Object? raw) => switch (raw) {
  ['element', final String id] => ElementTarget(id),
  ['lineup', final String id] => LineupTarget(id),
  _ => null,
};

Map<String, Object?> _sightingJson(_Sighting sighting) => switch (sighting) {
  _Seen(:final revision, :final digest, :final life, :final payloadVersion) => {
    'revision': revision,
    'digest': digest,
    'life': life.name,
    'payloadVersion': ?payloadVersion,
  },
  _Unreadable() => {'unreadable': true},
  _Absent() => {'absent': true},
};

_Sighting? _sightingFrom(Map<String, Object?> raw) {
  if (raw['unreadable'] == true) return const _Unreadable();
  if (raw['absent'] == true) return const _Absent();
  return switch ((
    raw['revision'],
    raw['digest'],
    raw['life'],
    raw['payloadVersion'],
  )) {
    (
      final num revision,
      final String digest,
      final String life,
      final Object? version,
    )
        when isSafeWhole(revision) &&
            Life.values.asNameMap().containsKey(life) &&
            (version == null || (version is num && isSafeWhole(version))) =>
      _Seen(
        revision.toInt(),
        digest,
        Life.values.asNameMap()[life]!,
        (version as num?)?.toInt(),
      ),
    _ => null,
  };
}

int? _readFrom(Object? raw) => switch (raw) {
  final num read when isSafeWhole(read) && read >= 1 => read.toInt(),
  _ => null,
};

SeenPart? _partFrom(Object? raw) => switch (raw) {
  'settings' => const SeenSettings(),
  final String text when text.startsWith('element:') => SeenElement(
    text.substring('element:'.length),
  ),
  final String text when text.startsWith('lineup:') => SeenLineupGroup(
    text.substring('lineup:'.length),
  ),
  _ => null,
};

final class _GroupReader {
  _GroupReader(this.nameOf);

  final String Function(String? page) nameOf;
  final rows = <Target, _Said>{};
  final pages = <String, _PageSaid>{};
  final settings = <String, _ReadSaid>{};
  final content = <String, _ContentSaid>{};
  _ReadSaid? strategy;
  int headers = 0;

  String? group(String name, String text) {
    final Object? decoded;
    switch (admit(text)) {
      case Admitted(:final json):
        decoded = plainJson(json);
      case NotAdmitted(:final problem):
        return problem;
    }
    if (decoded is! Map<String, Object?>) return 'expected an object';
    if (decoded['version'] != evidenceRowVersion) {
      return 'an evidence version this build does not read';
    }
    final page = switch (decoded['page']) {
      final String page => page,
      null => null,
      _ => '',
    };
    if (page == '' || nameOf(page) != name) {
      return 'evidence kept under another name';
    }
    if (page == null) return _header(decoded);
    return _page(page, decoded);
  }

  String? _header(Map<String, Object?> decoded) {
    for (final key in decoded.keys) {
      if (!const {'version', 'strategy', 'headers'}.contains(key)) {
        return 'an unknown field "$key" in the header evidence';
      }
    }
    if (decoded['strategy'] case final Map<String, Object?> raw) {
      final read = _readFrom(raw['read']);
      final sighting = _sightingFrom(raw);
      if (read == null || sighting == null) return 'an unreadable strategy';
      strategy = _ReadSaid(read, sighting);
    }
    if (decoded.containsKey('headers')) {
      final read = _readFrom(decoded['headers']);
      if (read == null) return 'an unreadable header read';
      headers = read;
    }
    return null;
  }

  String? _page(String page, Map<String, Object?> decoded) {
    for (final key in decoded.keys) {
      if (!const {
        'version',
        'page',
        'existence',
        'settings',
        'content',
        'rows',
      }.contains(key)) {
        return 'an unknown field "$key" in page evidence';
      }
    }
    if (decoded['existence'] case final Map<String, Object?> raw) {
      final read = _readFrom(raw['read']);
      final since = raw['since'];
      final sighting = _sightingFrom(raw);
      if (read == null ||
          sighting == null ||
          since is! num ||
          !isSafeWhole(since) ||
          since < 0) {
        return 'an unreadable page existence';
      }
      pages[page] = _PageSaid(read, sighting, since.toInt());
    }
    if (decoded['settings'] case final Map<String, Object?> raw) {
      final read = _readFrom(raw['read']);
      final sighting = _sightingFrom(raw);
      if (read == null || sighting == null) return 'unreadable settings';
      settings[page] = _ReadSaid(read, sighting);
    }
    if (decoded['content'] case final Map<String, Object?> raw) {
      final read = _readFrom(raw['read']);
      final digests = <SeenPart, String>{};
      final present = <Target>{};
      if (raw['digests'] case final List<Object?> list) {
        for (final item in list) {
          if (item case [final Object? name, final String digest]) {
            final part = _partFrom(name);
            if (part == null) return 'unreadable content';
            digests[part] = digest;
          } else {
            return 'unreadable content';
          }
        }
      } else {
        return 'unreadable content';
      }
      if (raw['present'] case final List<Object?> list) {
        for (final item in list) {
          final target = _targetFrom(item);
          if (target == null) return 'unreadable content';
          present.add(target);
        }
      } else {
        return 'unreadable content';
      }
      if (read == null) return 'unreadable content';
      content[page] = _ContentSaid(read, digests, present);
    }
    if (decoded['rows'] case final List<Object?> list) {
      for (final item in list) {
        if (item is! Map<String, Object?>) return 'an unreadable row statement';
        final target = _targetFrom(item['target']);
        final read = _readFrom(item['read']);
        final sighting = _sightingFrom(item);
        if (target == null ||
            read == null ||
            sighting == null ||
            sighting is _Absent ||
            rows.containsKey(target)) {
          return 'an unreadable row statement';
        }
        rows[target] = _Said(read, page, sighting);
      }
    } else if (decoded.containsKey('rows')) {
      return 'an unreadable row statement';
    }
    return null;
  }

  Evidence build() => Evidence._(
    rows: rows,
    pages: pages,
    settings: settings,
    content: content,
    strategy: strategy,
    headers: headers,
  );
}
