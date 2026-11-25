import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/dev/drive/drive_library_store.dart';
import 'package:icarus/dev/drive/drive_page_take.dart';
import 'package:icarus_library/icarus_library.dart' show shownTakesChecked;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('without a budget the step logs its one TAKE line', () async {
    final lines = await pageTakeCost(items: 60, changed: 1, runs: 3);

    expect(lines, hasLength(1));
    expect(lines.single, startsWith('TAKE 1 of 60 items changed, 3 results:'));
  });

  test(
    'within budget the step logs each measured value beside its target',
    () async {
      final lines = await pageTakeCost(
        items: 60,
        changed: 1,
        runs: 3,
        budget: const PageTakeBudget(longestStepMs: 60000, recordMs: 60000),
      );

      expect(lines, hasLength(3));
      expect(
        lines[1],
        matches(
          RegExp(
            r'^TAKE 1 of 60 items changed within budget: longest '
            r'step median of 3 takes \d+\.\d\d ms, target 60000 ms$',
          ),
        ),
      );
      expect(
        lines[2],
        matches(
          RegExp(
            r'^TAKE 1 of 60 items changed within budget: record '
            r'median of 3 takes \d+\.\d\d ms, target 60000 ms$',
          ),
        ),
      );
    },
  );

  test('over budget the step fails, naming each value over its target and by '
      'how much', () async {
    final failed =
        await pageTakeCost(
          items: 60,
          changed: 1,
          runs: 3,
          budget: const PageTakeBudget(longestStepMs: 0, recordMs: 60000),
        ).then<StoreStepFailed?>(
          (_) => null,
          onError: (Object error) => error as StoreStepFailed,
        );

    expect(failed, isNotNull);
    expect(failed!.problems, hasLength(3));
    expect(
      failed.problems[1],
      matches(
        RegExp(
          r'^TAKE 1 of 60 items changed over budget: longest step '
          r'median of 3 takes (\d+\.\d\d) ms, target 0 ms, over by \1 ms; '
          r'PC busy \S+ before, \S+ after$',
        ),
      ),
    );
    expect(failed.problems[2], contains('within budget: record'));
  });

  test('the step leaves takes checked as it found them', () async {
    final before = shownTakesChecked;
    await pageTakeCost(items: 60, changed: 1, runs: 1);

    expect(shownTakesChecked, before);
  });
}
