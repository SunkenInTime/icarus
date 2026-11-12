/// One attempt to open a strategy in the editor.
///
/// Opening takes several waits (the disk, the server, the pages), and the
/// reader can leave or open something else during any of them. An open that
/// gave way must do nothing further: not mark itself open, not touch the save
/// state or the upload queue, which by then belong to whatever replaced it.
///
/// So every wait inside an open goes through [wait], which ends the open
/// right there if it gave way. test/open_attempt_test.dart reads the
/// functions an open is made of and fails on an `await` in them that does
/// not; a function they call that waits on its own has to be given the
/// attempt and added to that list.
class OpenAttempt {
  OpenAttempt(this._isCurrent);

  /// An attempt nothing supersedes, for a caller that is not an open.
  static final unchallenged = OpenAttempt(() => true);

  final bool Function() _isCurrent;

  /// Whether this open is still the one wanted.
  bool get isCurrent => _isCurrent();

  /// Waits for [step], then throws [OpenGaveWay] if this open was closed or
  /// replaced meanwhile. Whoever started the attempt catches it.
  Future<T> wait<T>(Future<T> step) async {
    final result = await step;
    if (!isCurrent) throw const OpenGaveWay();
    return result;
  }
}

/// Ends an open that was closed, or replaced by a newer one, while it waited.
class OpenGaveWay implements Exception {
  const OpenGaveWay();

  @override
  String toString() => 'The open gave way to something newer.';
}
