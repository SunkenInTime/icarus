import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/local_library.dart';

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

  var made = 0;
  Future<StrategyData> stored({Optionals optionals = Optionals.set}) async {
    made += 1;
    final id = 'hive-open-$made';
    final strategy = generatedStrategy(optionals).copyWith(
      id: id,
      pages: [
        for (final (index, sortIndex) in [1, 0, 0].indexed)
          generatedPage(
            id: '$id-p$index',
            sortIndex: sortIndex,
            optionals: optionals,
            isAttack: index.isEven,
            itemPrefix: '$id-p$index',
          ),
      ],
    );
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(strategy.id, strategy);
    return strategy;
  }

  StrategyProvider editor() => container.read(strategyProvider.notifier);
  String? caption() => container.read(agentProvider).first.caption;

  test(
      'a local open shows the first page in sort order, lists the pages in '
      'sort order with tied positions kept in their stored order, and draws '
      'the stored theme', () async {
    final s = await stored();
    expect(s.themeProfileId, isNotNull);

    expect(await editor().loadFromHive(s.id), isTrue);

    final session = container.read(strategyPageSessionProvider);
    expect(session.activePageId, s.pages[1].id);
    expect(session.availablePageIds,
        [s.pages[1].id, s.pages[2].id, s.pages[0].id]);
    expect(caption(), s.pages[1].agentData.first.caption);
    final theme = container.read(strategyThemeProvider);
    expect(theme.profileId, s.themeProfileId);
    expect(theme.overridePalette?.toJson(), s.themeOverridePalette?.toJson());
  });

  test('a strategy that names no theme opens on the default profile', () async {
    final s = await stored(optionals: Optionals.unset);
    expect(s.themeProfileId, isNull);

    expect(await editor().loadFromHive(s.id), isTrue);

    expect(container.read(strategyThemeProvider).profileId,
        MapThemeProfilesProvider.immutableDefaultProfileId);
  });

  test('a page switch reads Hive\'s record as it is at the switch', () async {
    final s = await stored();
    expect(await editor().loadFromHive(s.id), isTrue);
    final behind = const LocalLibrary().storedStrategy(s.id)!;
    behind.pages[2].agentData.first.caption = 'written behind the editor';
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(s.id, behind);

    await editor().setActivePage(s.pages[2].id);

    expect(caption(), 'written behind the editor');
  });

  test(
      'a page switch with no edit writes the page it leaves to Hive: the '
      'time moves on and a strategy that named no theme now names the '
      'default', () async {
    final s = await stored(optionals: Optionals.unset);
    expect(await editor().loadFromHive(s.id), isTrue);
    final before = const LocalLibrary().storedStrategy(s.id)!.lastEdited;
    final writes = <Object?>[];
    final watching = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .watch(key: s.id)
        .listen((event) => writes.add(event.key));
    addTearDown(watching.cancel);

    await editor().setActivePage(s.pages[2].id);
    await Future<void>.delayed(Duration.zero);

    final after = const LocalLibrary().storedStrategy(s.id)!;
    expect(writes, [s.id]);
    expect(after.lastEdited.isAfter(before), isTrue);
    expect(after.themeProfileId,
        MapThemeProfilesProvider.immutableDefaultProfileId);
  });
}
