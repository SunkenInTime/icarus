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
      'deleted': false,
    }));

PageSettingsRow _settings(String pagePublicId, RemotePageContent content) =>
    _read(PageSettingsRow.decode({
      'pagePublicId': pagePublicId,
      if (content.settings case final settings?) 'settings': settings,
      'revision': content.revision,
    }));

ElementRow _element(RemoteElement element, CanRead canRead) =>
    _read(ElementRow.decode({
      'publicId': element.publicId,
      'pagePublicId': element.pagePublicId,
      'payload': element.payload,
      'sortIndex': element.sortIndex,
      'revision': element.revision,
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
    _rows(
      () => PageRead(
        page: _page(page.page),
        elements: [
          for (final element in page.elements) _element(element, canRead),
        ],
        lineupGroups: [
          for (final lineup in page.lineups) _lineupGroup(lineup, canRead),
        ],
      ),
    );
