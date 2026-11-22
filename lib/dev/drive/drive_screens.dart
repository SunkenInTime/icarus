import 'package:flutter/foundation.dart';
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
  final _wrapped = <VoidCallback, VoidCallback>{};

  @override
  T get value => _source.value;

  @override
  void addListener(VoidCallback listener) {
    final counting = _wrapped[listener] ??= () {
      _notified.update(_what, (count) => count + 1, ifAbsent: () => 1);
      listener();
    };
    _source.addListener(counting);
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_wrapped.remove(listener) case final counting?) {
      _source.removeListener(counting);
    }
  }
}

bool _laidOut(Element element) => switch (element.findRenderObject()) {
      final RenderBox box => box.attached && box.hasSize,
      _ => false,
    };

String _drawn(Element root) {
  final parts = <String>[];
  void visit(Element element, bool insideText) {
    final widget = element.widget;
    var inside = insideText;
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

List<String> libraryOnScreen() {
  final lines = <String>[];
  void visit(Element element) {
    final kind = switch (element.widget) {
      StrategyTile() => 'strategy',
      FolderCard() => 'folder',
      _ => null,
    };
    if (kind != null) {
      if (_laidOut(element)) {
        lines.add('$kind ${element.widget.key} ${_drawn(element)}');
      }
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return lines;
}

List<String> pagesBarOnScreen() {
  final lines = <String>[];
  void visit(Element element) {
    if (element.widget is PagesBar) {
      if (_laidOut(element)) lines.add(_drawn(element));
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return lines;
}
