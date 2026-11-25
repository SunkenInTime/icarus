import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/dev/drive/drive_library_store.dart';
import 'package:icarus/strategy/strategy_models.dart';

import '../library_rows/generated_strategies.dart';
import 'unit_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await openUnitHive();
    final strategy = generatedStrategy(Optionals.set).copyWith(
      id: 'budgeted',
      name: 'Budgeted',
      pages: [
        for (final index in [0, 1])
          generatedPage(
            id: 'budgeted-p$index',
            sortIndex: index,
            optionals: Optionals.set,
            isAttack: index.isEven,
            itemPrefix: 'budgeted-p$index',
          ).copyWith(imageData: const []),
      ],
    );
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(strategy.id, strategy);
  });
  tearDown(Hive.close);

  test('without a budget the step logs its one READBACK line', () async {
    final lines = await readBackCost('Budgeted', 3);

    expect(lines, hasLength(1));
    expect(lines.single, startsWith('READBACK Budgeted (2 pages'));
  });

  test('within budget the step logs each measured value beside its target',
      () async {
    final lines = await readBackCost(
      'Budgeted',
      3,
      budget: const ReadBackBudget(longestStepMs: 60000, addedPerSaveMs: 60000),
    );

    expect(lines, hasLength(3));
    expect(
      lines[1],
      matches(RegExp(r'^READBACK Budgeted within budget: longest step '
          r'\d+\.\d\d ms, target 60000 ms$')),
    );
    expect(
      lines[2],
      matches(RegExp(r'^READBACK Budgeted within budget: added per save '
          r'-?\d+\.\d\d ms, target 60000 ms$')),
    );
  });

  test(
      'over budget the step fails, naming each value over its target and by '
      'how much', () async {
    final failed = await readBackCost(
      'Budgeted',
      3,
      budget: const ReadBackBudget(longestStepMs: 0, addedPerSaveMs: 60000),
    ).then<StoreStepFailed?>((_) => null,
        onError: (Object error) => error as StoreStepFailed);

    expect(failed, isNotNull);
    expect(failed!.problems, hasLength(3));
    expect(
      failed.problems[1],
      matches(RegExp(r'^READBACK Budgeted over budget: longest step '
          r'(\d+\.\d\d) ms, target 0 ms, over by \1 ms$')),
    );
    expect(failed.problems[2], contains('within budget: added per save'));
  });
}
