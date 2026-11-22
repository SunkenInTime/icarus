import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/strategy/local_library.dart';

final class _Silent extends LocalLibraryFollower {
  @override
  void onWriting(LibraryTouch touch) {}

  @override
  void onAnswered(LibraryTouch touch) {}

  @override
  void onFault(Object error, StackTrace stackTrace) {}
}

final class _CloseNeverAnswers extends LibraryStoreNotifier {
  @override
  Future<void> close() => Completer<void>().future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => LocalLibrary.follower = null);

  test('only a mirroring store makes the editor wait before it closes', () {
    LocalLibrary.follower = null;
    expect(storeIsMirroring(), isFalse);
    LocalLibrary.follower = _Silent();
    expect(storeIsMirroring(), isFalse);
    LocalLibrary.follower = StoreMirror(
      readHive: () => throw StateError('not read'),
      reads: const HiveLibraryReads(),
      betweenAnimations: () async {},
    );
    expect(storeIsMirroring(), isTrue);
  });

  test('a store close that never answers lets the app exit after two seconds',
      () async {
    final container = ProviderContainer(overrides: [
      libraryStoreProvider.overrideWith(_CloseNeverAnswers.new),
    ]);
    final watch = Stopwatch()..start();
    await storeClosesBeforeExit(container).timeout(const Duration(seconds: 5));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    container.dispose();
  });
}
