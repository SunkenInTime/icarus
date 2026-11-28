import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/store_startup.dart';

final class _SlowClose extends LibraryStoreNotifier {
  var finished = false;

  @override
  Future<void> close() async {
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    finished = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the close at exit returns only once the store has closed', () async {
    final slow = _SlowClose();
    final container = ProviderContainer(overrides: [
      libraryStoreProvider.overrideWith(() => slow),
    ]);
    addTearDown(container.dispose);
    await storeClosesBeforeExit(container);
    expect(slow.finished, isTrue);
  });
}
