import 'package:icarus/share/pending_share_code_store_stub.dart'
    if (dart.library.js_interop) 'package:icarus/share/pending_share_code_store_web.dart'
    as platform;

/// Holds a share code that is waiting for the user to sign in.
///
/// On web, Discord sign-in navigates the tab away and back, which restarts
/// the app, so the code must outlive the page: the web store keeps it in the
/// tab's sessionStorage. Native sign-in never restarts the app, so memory is
/// enough there.
abstract interface class PendingShareCodeStore {
  String? read();
  void write(String code);
  void clear();
}

class MemoryPendingShareCodeStore implements PendingShareCodeStore {
  String? _code;

  @override
  String? read() => _code;

  @override
  void write(String code) => _code = code;

  @override
  void clear() => _code = null;
}

/// sessionStorage on web, memory on native.
PendingShareCodeStore createPendingShareCodeStore() =>
    platform.createPendingShareCodeStore();
