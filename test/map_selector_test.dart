import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/map_selector.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  late Directory tempDir;

  setUpAll(() => registerIcarusAdapters(Hive));

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-map-selector-');
    Hive.init(tempDir.path);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  testWidgets('a map selector whose list was never opened leaves quietly',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: ShadApp(home: Scaffold(body: MapSelector())),
      ),
    );
    expect(find.byType(MapSelector), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());

    expect(tester.takeException(), isNull);
  });
}
