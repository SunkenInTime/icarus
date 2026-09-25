import 'dart:js_interop';

import 'package:icarus/services/open_cloud_strategy_store.dart';

OpenCloudStrategyStore createOpenCloudStrategyStore() =>
    _SessionOpenCloudStrategyStore();

@JS('sessionStorage')
external _Storage get _sessionStorage;

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

/// Keeps the id in this tab's sessionStorage, which survives a reload and
/// dies with the tab. If the browser refuses storage (some privacy modes
/// throw on access), the id lives in memory and a reload returns to the
/// library.
class _SessionOpenCloudStrategyStore implements OpenCloudStrategyStore {
  static const _key = 'icarus.openCloudStrategy';
  final _fallback = MemoryOpenCloudStrategyStore();

  @override
  String? read() {
    try {
      return _sessionStorage.getItem(_key);
    } catch (_) {
      return _fallback.read();
    }
  }

  @override
  void write(String strategyPublicId) {
    try {
      _sessionStorage.setItem(_key, strategyPublicId);
    } catch (_) {
      _fallback.write(strategyPublicId);
    }
  }

  @override
  void clear() {
    _fallback.clear();
    try {
      _sessionStorage.removeItem(_key);
    } catch (_) {}
  }
}
