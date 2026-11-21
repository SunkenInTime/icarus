import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/library_store/ui_watch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the watch stops at once when no frame comes, and says it saw none',
      () async {
    final watch = UiWatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final stats = watch.stop();
    expect(stats, isA<UiNoFrames>());
    expect(stats.toString(), contains('no frame was drawn'));
  });
}
