import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Rebuilds [builder] only when what [select] reads from [listenable]
/// changes. Playback notifies every frame; most of the panels around the
/// map show something that changes a few times a round, and rebuilding them
/// at 165 Hz is most of a frame's budget.
class ReplaySelect<T> extends StatefulWidget {
  const ReplaySelect({
    super.key,
    required this.listenable,
    required this.select,
    required this.builder,
    this.equals,
  });

  final Listenable listenable;
  final T Function() select;
  final Widget Function(BuildContext context, T value) builder;

  /// How two selections compare; `==` by default, element by element for
  /// lists.
  final bool Function(T a, T b)? equals;

  @override
  State<ReplaySelect<T>> createState() => _ReplaySelectState<T>();
}

class _ReplaySelectState<T> extends State<ReplaySelect<T>> {
  late T _value = widget.select();

  bool _same(T a, T b) {
    final equals = widget.equals;
    if (equals != null) return equals(a, b);
    if (a is List && b is List) return listEquals(a, b);
    return a == b;
  }

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(ReplaySelect<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _value = widget.select();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final next = widget.select();
    if (_same(_value, next)) return;
    setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
