import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/folder_navigator.dart';

import 'editor_on_screen_support.dart';
import 'library_store/unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer(overrides: [
    authProvider.overrideWith(_SignedOut.new),
  ]);
  appProviderContainer = container;
  final strategies = container.read(strategyProvider.notifier);
  setUp(openUnitHive);
  tearDown(closeUnitHive);

  testWidgets(
      'New Strategy opens the strategy it made when something closed above '
      'the map picker while it was up', (tester) async {
    await pumpLibraryWithEditors(tester, container);
    unawaited(
      pickMapAndOpenNewStrategy(ref: libraryRef, context: libraryContext),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(strategies.closeStrategy(asked: strategies.askedByTheUserNow()),
        isA<Changed>());

    final before = {...Hive.box<StrategyData>(HiveBoxNames.strategiesBox).keys};
    await tester.tap(find
        .byWidgetPredicate(
            (widget) => '${widget.key}'.contains('create-strategy-map-'))
        .first);
    await settleWithDisk(tester);

    final made = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .keys
        .where((id) => !before.contains(id))
        .toList();
    expect(made, hasLength(1));
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    expect(container.read(strategyProvider).strategyId, made.single);
    await leaveEditors(tester, container);
    await closeHive(tester);
  });
}
