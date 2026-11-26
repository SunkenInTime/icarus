import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:icarus/strategy_view.dart';

import 'editor_on_screen_support.dart';
import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

Future<void> _stored(String id) async {
  final strategy = generatedStrategy(Optionals.set).copyWith(id: id, name: id);
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(strategy.id, strategy);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer(overrides: [
    authProvider.overrideWith(_SignedOut.new),
  ]);
  appProviderContainer = container;
  final strategies = container.read(strategyProvider.notifier);
  setUp(openUnitHive);
  tearDown(Hive.close);

  testWidgets(
      'the window keeps asking before it closes while an editor is on '
      'screen, also after an editor that gave way left', (tester) async {
    await tester.runAsync(() async {
      await _stored('first');
      await _stored('second');
    });
    final preventClose = await pumpLibraryWithEditors(tester, container);
    final navigator = appNavigatorKey.currentState!;

    for (final id in ['first', 'second']) {
      expect(
        StrategyView.open(
          navigator,
          asked: strategies.askedByTheUserNow(),
          initialStrategyId: id,
          initialStrategyName: id,
        ),
        isA<Pushed>(),
      );
    }
    await settleWithDisk(tester);

    expect(container.read(strategyProvider).strategyId, 'second');
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    expect(preventClose, [true]);
    await leaveEditors(tester, container);
  });
}
