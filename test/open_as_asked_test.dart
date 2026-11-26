import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:icarus/strategy_view.dart';

import 'editor_on_screen_support.dart';
import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _CountingStrategies extends StrategyProvider {
  var cancels = 0;

  @override
  void cancelPendingSave() {
    cancels += 1;
    super.cancelPendingSave();
  }
}

Future<StrategyData> _stored(String id) async {
  final strategy = generatedStrategy(Optionals.set).copyWith(id: id, name: id);
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(strategy.id, strategy);
  return strategy;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _CountingStrategies strategies;
  setUpAll(() {
    final counting = _CountingStrategies();
    container = ProviderContainer(overrides: [
      authProvider.overrideWith(_SignedOut.new),
      strategyProvider.overrideWith(() => counting),
    ]);
    appProviderContainer = container;
    container.read(strategyProvider);
    strategies = counting;
  });
  setUp(openUnitHive);
  tearDown(() async {
    expect(strategies.closeStrategy(asked: strategies.askedByTheUserNow()),
        isA<Changed>());
    await Hive.close();
  });

  group('an open or close asked about what is no longer open', () {
    Future<OpenSeen> openedWithUnsavedWork(String id) async {
      await _stored(id);
      expect(
        await strategies.openLocal(id, asked: strategies.askedByTheUserNow()),
        isA<Changed>(),
      );
      container.read(strategySaveStateProvider.notifier).markDirty();
      return strategies.askedByTheUserNow();
    }

    test(
        'an open gives way and leaves the strategy open now, its unsaved '
        'work, its pending save and the count of opens as they were', () async {
      await _stored('asked-about');
      final askedEarlier = strategies.askedByTheUserNow();
      final now = await openedWithUnsavedWork('opened-since');
      final cancels = strategies.cancels;

      expect(
        await strategies.openLocal('asked-about', asked: askedEarlier),
        isA<GaveWay>(),
      );

      expect(container.read(strategyProvider).strategyId, 'opened-since');
      expect(container.read(strategySaveStateProvider).isDirty, isTrue);
      expect(strategies.cancels, cancels);
      expect(now.isNow(strategies.askedByTheUserNow()), isTrue);
    });

    test(
        'a close gives way and leaves the strategy open now, its unsaved '
        'work, its pending save and the count of opens as they were', () async {
      final askedEarlier = strategies.askedByTheUserNow();
      final now = await openedWithUnsavedWork('opened-since');
      final cancels = strategies.cancels;

      expect(strategies.closeStrategy(asked: askedEarlier), isA<GaveWay>());

      expect(container.read(strategyProvider).strategyId, 'opened-since');
      expect(container.read(strategySaveStateProvider).isDirty, isTrue);
      expect(strategies.cancels, cancels);
      expect(now.isNow(strategies.askedByTheUserNow()), isTrue);
    });

    test('the open the user asked for still opens after a late one gave way',
        () async {
      await _stored('late');
      await _stored('wanted');
      final askedEarlier = strategies.askedByTheUserNow();
      await openedWithUnsavedWork('in-between');
      final wanted = strategies.askedByTheUserNow();

      expect(
        await strategies.openLocal('late', asked: askedEarlier),
        isA<GaveWay>(),
      );
      expect(
          await strategies.openLocal('wanted', asked: wanted), isA<Changed>());
      expect(container.read(strategyProvider).strategyId, 'wanted');
    });
  });

  testWidgets(
      'a late editor push gives way whether it arrives while the wanted '
      'editor waits for its first frame or after it opened, and the wanted '
      'one opens', (tester) async {
    await tester.runAsync(() async {
      await _stored('wanted');
      await _stored('late');
    });
    await pumpLibraryWithEditors(tester, container);
    final navigator = appNavigatorKey.currentState!;
    final lateAsked = strategies.askedByTheUserNow();

    expect(
      StrategyView.open(
        navigator,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'wanted',
        initialStrategyName: 'wanted',
      ),
      isA<Pushed>(),
    );
    final beforeItsFirstFrame = StrategyView.open(
      navigator,
      asked: lateAsked,
      initialStrategyId: 'late',
      initialStrategyName: 'late',
    );
    await settleWithDisk(tester);

    expect(beforeItsFirstFrame, isA<Refused>());
    expect(container.read(strategyProvider).strategyId, 'wanted');
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);

    final afterItOpened = StrategyView.open(
      navigator,
      asked: lateAsked,
      initialStrategyId: 'late',
      initialStrategyName: 'late',
    );
    await settleWithDisk(tester);

    expect(afterItOpened, isA<Refused>());
    expect(container.read(strategyProvider).strategyId, 'wanted');
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    await leaveEditors(tester, container);
  });
}
