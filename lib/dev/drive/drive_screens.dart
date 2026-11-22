import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/widgets/folder_card.dart';
import 'package:icarus/widgets/pages_bar.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';

final _builds = <String, int>{};
final _notified = <String, int>{};

void countDriveBuild(String what) =>
    _builds.update(what, (count) => count + 1, ifAbsent: () => 1);

String _counts(Map<String, int> counts) => [
      for (final what in counts.keys.toList()..sort()) '$what=${counts[what]}',
    ].join(' ');

final _events = <String, int>{};

void countLibraryBoxEvent(String what) =>
    _events.update(what, (count) => count + 1, ifAbsent: () => 1);

String buildCounts() => '${_counts(_builds)}; NOTIFIED ${_counts(_notified)}; '
    'EVENTS ${_counts(_events)}';

String buildsLine() => 'BUILDS ${buildCounts()}';

final _counted = Expando<ValueListenable<Object?>>('counted for the driver');

ValueListenable<T> countedForDrive<T>(ValueListenable<T> source, String what) =>
    (_counted[source] ??= _Counted<T>(source, what)) as ValueListenable<T>;

final class _Counted<T> implements ValueListenable<T> {
  _Counted(this._source, this._what);

  final ValueListenable<T> _source;
  final String _what;
  final _wrapped = <VoidCallback, ({VoidCallback counting, int added})>{};

  @override
  T get value => _source.value;

  @override
  void addListener(VoidCallback listener) {
    final wrapped = _wrapped[listener] ??
        (
          counting: () {
            _notified.update(_what, (count) => count + 1, ifAbsent: () => 1);
            listener();
          },
          added: 0,
        );
    _wrapped[listener] = (counting: wrapped.counting, added: wrapped.added + 1);
    _source.addListener(wrapped.counting);
  }

  @override
  void removeListener(VoidCallback listener) {
    switch (_wrapped[listener]) {
      case null:
        return;
      case (:final counting, added: 1):
        _wrapped.remove(listener);
        _source.removeListener(counting);
      case (:final counting, :final added):
        _wrapped[listener] = (counting: counting, added: added - 1);
        _source.removeListener(counting);
    }
  }
}

Rect _onScreenRect(RenderBox box) => MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );

bool _onScreen(Element element) {
  final box = element.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return false;
  final drawn = _onScreenRect(box);
  for (var above = box.parent; above != null; above = above.parent) {
    if (above case final RenderBox viewport
        when viewport is RenderAbstractViewport) {
      if (!drawn.overlaps(_onScreenRect(viewport))) return false;
    }
  }
  return true;
}

String _drawn(Element root) {
  final parts = <String>[];
  void visit(Element element, bool insideText) {
    final widget = element.widget;
    var inside = insideText;
    if (widget is Text ||
        widget is RichText ||
        widget is Image ||
        widget is Icon) {
      if (!_onScreen(element)) return;
    }
    switch (widget) {
      case Text(:final data, :final textSpan) when !insideText:
        parts.add('"${data ?? textSpan?.toPlainText() ?? ''}"');
        inside = true;
      case RichText(:final text) when !insideText:
        parts.add('"${text.toPlainText()}"');
        inside = true;
      case Image(:final image):
        parts.add('image ${switch (image) {
          AssetImage(:final assetName) => assetName,
          ExactAssetImage(:final assetName) => assetName,
          final other => other.runtimeType,
        }}');
      case Icon(:final icon?):
        parts.add('icon ${icon.codePoint.toRadixString(16)}');
      default:
        break;
    }
    element.visitChildElements((child) => visit(child, inside));
  }

  visit(root, false);
  return parts.join(' ');
}

typedef DrawnItem = ({String kind, Key? key, String drawn});

@visibleForTesting
List<DrawnItem> drawnOnScreen(String? Function(Widget widget) kindOf) {
  final items = <DrawnItem>[];
  void visit(Element element) {
    if (kindOf(element.widget) case final kind?) {
      if (_onScreen(element)) {
        items
            .add((kind: kind, key: element.widget.key, drawn: _drawn(element)));
      }
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return items;
}

List<String> libraryOnScreen() => [
      for (final item in drawnOnScreen(
        (widget) => switch (widget) {
          StrategyTile() => 'strategy',
          FolderCard() => 'folder',
          _ => null,
        },
      ))
        '${item.kind} ${item.key} ${item.drawn}',
    ];

List<String> pagesBarOnScreen() => [
      for (final item in drawnOnScreen(
        (widget) => widget is PagesBar ? 'pages bar' : null,
      ))
        item.drawn,
    ];
