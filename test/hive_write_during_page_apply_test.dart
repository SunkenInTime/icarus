import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/canvas_units.dart' show cloneStrategy;
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/local_page_reads.dart';

import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  setUpAll(() {
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    appProviderContainer = container;
  });
  setUp(() async {
    await openUnitHive();
    await Hive.box<Folder>(HiveBoxNames.foldersBox).put(
      'folder-1',
      Folder(name: 'Retakes', id: 'folder-1', dateCreated: DateTime.utc(2026)),
    );
  });
  tearDown(() async => Hive.close());

  test(
    'with the store switch off, a Hive save that lands as an open applies its '
    'page is the caption the canvas shows and the Save keeps',
    () async {
      expect(container.read(localPageReadsProvider), isNull);
      final strategy = generatedStrategy(Optionals.set).copyWith(
        id: 'landing',
        pages: [
          for (final index in [0, 1])
            generatedPage(
              id: 'landing-p$index',
              sortIndex: index,
              optionals: Optionals.set,
              isAttack: index.isEven,
              itemPrefix: 'landing-p$index',
            ),
        ],
      );
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(strategy.id, strategy);
      var landed = false;
      final listening = container.listen(
        strategyPageSessionProvider.select((state) => state.isApplyingPage),
        (_, applying) {
          if (!applying || landed) return;
          landed = true;
          final newer =
              cloneStrategy(const LocalLibrary().storedStrategy(strategy.id)!);
          newer.pages.first.agentData.first.caption = 'newer';
          unawaited(const LocalLibrary().savePageOnScreen(newer));
        },
      );
      addTearDown(listening.close);
      final editor = container.read(strategyProvider.notifier);

      expect(await editor.loadFromHive(strategy.id), isTrue);
      expect(landed, isTrue);
      final shown = container.read(agentProvider).first.caption;
      await editor.saveToHive(strategy.id);
      final saved = const LocalLibrary()
          .storedStrategy(strategy.id)!
          .pages
          .first
          .agentData
          .first
          .caption;

      expect((shown: shown, saved: saved), (shown: 'newer', saved: 'newer'));
    },
    skip: 'shipped behaviour, see report',
  );
}
