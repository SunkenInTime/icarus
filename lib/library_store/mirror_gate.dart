import 'package:icarus_library/icarus_library.dart';

final class GateShut implements Exception {
  const GateShut();

  @override
  String toString() => 'the mirror stopped';
}

final class Gate {
  const Gate(this.isShut);

  static final open = Gate(() => false);

  final bool Function() isShut;

  Future<T> pass<T>(Future<T> Function() work) async {
    if (isShut()) throw const GateShut();
    final T result;
    try {
      result = await work();
    } on Object {
      if (isShut()) throw const GateShut();
      rethrow;
    }
    if (isShut()) throw const GateShut();
    return result;
  }
}

final class GatedStore {
  const GatedStore(this._store, this._gate);

  GatedStore.open(LibraryStore store) : this(store, Gate.open);

  final LibraryStore _store;
  final Gate _gate;

  LibraryState get library => _store.library;

  Future<T> use<T>(Future<T> Function(LibraryStore store) work) =>
      _gate.pass(() => work(_store));
}
