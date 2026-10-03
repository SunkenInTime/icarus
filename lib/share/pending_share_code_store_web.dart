import 'dart:js_interop';

import 'package:icarus/share/pending_share_code_store.dart';

PendingShareCodeStore createPendingShareCodeStore() =>
    _SessionPendingShareCodeStore();

@JS('sessionStorage')
external _Storage get _sessionStorage;

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

/// Keeps the code in this tab's sessionStorage, which survives the Discord
/// round trip and dies with the tab. If the browser refuses storage (some
/// privacy modes throw on access), the code lives in memory for this page
/// only, which is how every build behaved before.
class _SessionPendingShareCodeStore implements PendingShareCodeStore {
  static const _key = 'icarus.pendingShareCode';
  final _fallback = MemoryPendingShareCodeStore();

  @override
  String? read() {
    try {
      return _sessionStorage.getItem(_key);
    } catch (_) {
      return _fallback.read();
    }
  }

  @override
  void write(String code) {
    try {
      _sessionStorage.setItem(_key, code);
    } catch (_) {
      _fallback.write(code);
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
