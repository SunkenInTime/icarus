import 'package:icarus/collab/collab_models.dart';
import 'package:icarus_library/icarus_library.dart';

class RemotePageList {
  const RemotePageList({required this.header, required this.pages});

  final RemoteStrategyHeader header;
  final List<RemoteFullPage> pages;
}

sealed class ResultRows<T> {
  const ResultRows();
}

final class RowsRead<T> extends ResultRows<T> {
  const RowsRead(this.value);

  final T value;
}

final class RowsUnreadable<T> extends ResultRows<T> {
  const RowsUnreadable(this.problem);

  final String problem;
}

final class _Unreadable implements Exception {
  const _Unreadable(this.problem);

  final String problem;
}

T _read<T>(Decoded<T> decoded) => switch (decoded) {
      Read(:final value) => value,
      CouldNotRead(:final problem) => throw _Unreadable(problem),
    };

ResultRows<T> _rows<T>(T Function() build) {
  try {
    return RowsRead(build());
  } on _Unreadable catch (unreadable) {
    return RowsUnreadable(unreadable.problem);
  }
}

int _millis(DateTime time) => time.millisecondsSinceEpoch;

StrategyRow _strategy(RemoteStrategyHeader header) => _read(StrategyRow.decode({
      'publicId': header.publicId,
      'name': header.name,
      'mapData': header.mapData,
      if (header.themeProfileId case final profile?) 'themeProfileId': profile,
      if (header.themeOverridePalette case final palette?)
        'themeOverridePalette': palette,
      'revision': header.revision,
      'createdAt': _millis(header.createdAt),
      'updatedAt': _millis(header.updatedAt),
    }));

PageRow _page(RemotePage page) => _read(PageRow.decode({
      'publicId': page.publicId,
      'strategyPublicId': page.strategyPublicId,
      'name': page.name,
      if (page.isAutoNamed case final autoNamed?) 'isAutoNamed': autoNamed,
      'sortIndex': page.sortIndex,
      'isAttack': page.isAttack,
      'revision': page.revision,
      'createdAt': _millis(page.createdAt),
      'deleted': false,
    }));

PageSettingsRow _settings(String pagePublicId, RemotePageContent content) =>
    _read(PageSettingsRow.decode({
      'pagePublicId': pagePublicId,
      if (content.settings case final settings?) 'settings': settings,
      'revision': content.revision,
      'createdAt': _millis(content.createdAt),
    }));

ElementRow _element(RemoteElement element, CanRead canRead) =>
    _read(ElementRow.decode({
      'publicId': element.publicId,
      'pagePublicId': element.pagePublicId,
      'payload': element.payload,
      'sortIndex': element.sortIndex,
      'revision': element.revision,
      if (element.createdAt case final createdAt?)
        'createdAt': _millis(createdAt),
      'deleted': element.deleted,
    }, canRead: canRead.element));

LineupGroupRow _lineupGroup(RemoteLineup lineup, CanRead canRead) =>
    _read(LineupGroupRow.decode({
      'publicId': lineup.publicId,
      'strategyPublicId': lineup.strategyPublicId,
      'pagePublicId': lineup.pagePublicId,
      'payload': lineup.payload,
      'sortIndex': lineup.sortIndex,
      'revision': lineup.revision,
      if (lineup.createdAt case final createdAt?)
        'createdAt': _millis(createdAt),
      'deleted': lineup.deleted,
    }, canRead: canRead.lineupGroup));

ResultRows<HeaderRead> pageListRead(RemotePageList list) => _rows(
      () => HeaderRead(
        strategy: _strategy(list.header),
        pages: [for (final page in list.pages) _page(page.page)],
        settings: [
          for (final page in list.pages)
            _settings(page.page.publicId, page.content),
        ],
      ),
    );

ResultRows<PageRead> pageRead(RemotePageSnapshot page, CanRead canRead) =>
    pageReadOver(page, canRead, held: HeldOnPage.nothing, decoded: () {});

ResultRows<PageRead> pageReadOver(
  RemotePageSnapshot page,
  CanRead canRead, {
  required HeldOnPage held,
  required void Function() decoded,
}) =>
    _rows(
      () => PageRead(
        page: _page(page.page),
        elements: [
          for (final element in page.elements)
            switch (held.elements[element.publicId]) {
              final row?
                  when _sameIdentity(
                    row,
                    page: element.pagePublicId,
                    revision: element.revision,
                    createdAt: element.createdAt,
                  ) =>
                row,
              _ => _decoded(decoded, () => _element(element, canRead)),
            },
        ],
        lineupGroups: [
          for (final lineup in page.lineups)
            switch (held.lineupGroups[lineup.publicId]) {
              final row?
                  when _sameIdentity(
                    row,
                    page: lineup.pagePublicId,
                    revision: lineup.revision,
                    createdAt: lineup.createdAt,
                  ) =>
                row,
              _ => _decoded(decoded, () => _lineupGroup(lineup, canRead)),
            },
        ],
      ),
    );

T _decoded<T>(void Function() counted, T Function() decode) {
  counted();
  return decode();
}

bool _sameIdentity(
  Row held, {
  required String page,
  required int revision,
  required DateTime? createdAt,
}) =>
    switch (held) {
      ElementRow(:final pagePublicId) ||
      LineupGroupRow(:final pagePublicId) =>
        pagePublicId == page,
      _ => false,
    } &&
    versionOfRow(held) ==
        Version(revision, life: createdAt?.millisecondsSinceEpoch);
