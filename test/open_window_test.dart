import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/open_seen.dart';

import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';
import 'opens_now_support.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _DiskGate {
  _DiskGate(this.directory);

  final Directory directory;
  Completer<void>? _held;
  Completer<void>? _reached;

  Future<void> holdNext() {
    _held = Completer<void>();
    return (_reached = Completer<void>()).future;
  }

  void release() => _held?.complete();

  Future<Object?> answer(MethodCall call) async {
    if (_reached case final reached? when !reached.isCompleted) {
      reached.complete();
      await _held!.future;
    }
    return directory.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _DiskGate gate;
  setUpAll(() {
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    appProviderContainer = container;
  });
  setUp(() async {
    gate = _DiskGate(await openUnitHive());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, gate.answer);
  });
  tearDown(closeUnitHive);

  StrategyData stored(String id) {
    final strategy = generatedStrategy(Optionals.set).copyWith(
      id: id,
      pages: [
        for (final index in [0, 1])
          generatedPage(
            id: '$id-p$index',
            sortIndex: index,
            optionals: Optionals.set,
            isAttack: true,
            itemPrefix: '$id-p$index',
          ),
      ],
    );
    unawaited(
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(id, strategy),
    );
    return strategy;
  }

  List<String> agentsSaved(String strategyId, String pageId) => [
        for (final agent in const LocalLibrary()
            .storedStrategy(strategyId)!
            .pages
            .firstWhere((page) => page.id == pageId)
            .agentData)
          agent.id,
      ];

  test(
      'a page clicked while an open of another strategy waits on the disk '
      'leaves the page on screen saved as it was', () async {
    final a = stored('window-a');
    final b = stored('window-b');
    final editor = container.read(strategyProvider.notifier);
    expect(await editor.loadFromHive(a.id), isTrue);
    final before = agentsSaved(a.id, a.pages[0].id);
    expect(before, isNotEmpty);

    final held = gate.holdNext();
    final opening = editor.loadFromHive(b.id);
    await held;
    final switching = editor.setActivePageAnimated(a.pages[1].id);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    gate.release();
    await opening;
    await switching;

    expect(agentsSaved(a.id, a.pages[0].id), before);
    expect(container.read(strategyProvider).strategyId, b.id);
    expect(container.read(strategyPageSessionProvider).activePageId,
        b.pages[0].id);
  });

  test(
      'a close asked about A while B was opening gives way once B is open, '
      'though the count of opens is the same', () async {
    final a = stored('window-a');
    final b = stored('window-b');
    final editor = container.read(strategyProvider.notifier);
    expect(await editor.loadFromHive(a.id), isTrue);

    final held = gate.holdNext();
    final opening = editor.openLocal(b.id, asked: editor.askedByTheUserNow());
    await held;
    final askedWhileAShows = editor.askedByTheUserNow();
    expect(askedWhileAShows.strategyId, a.id);
    gate.release();
    expect(await opening, isA<Changed>());
    expect(editor.askedByTheUserNow().opens, askedWhileAShows.opens);

    expect(editor.closeStrategy(asked: askedWhileAShows), isA<GaveWay>());
    expect(container.read(strategyProvider).strategyId, b.id);
  });
}
