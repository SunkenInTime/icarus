import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:icarus/strategy/open_seen.dart';

const _reportsOfTheTestFontAndTeardown = [
  'overflowed',
  "Looking up a deactivated widget's ancestor is unsafe",
  'Cannot get renderObject of inactive element',
];

FlutterExceptionHandler? _reportedBeforeTheEditor;

Future<void> pumpLibraryWithEditors(
  WidgetTester tester,
  ProviderContainer container,
) async {
  tester.view.physicalSize = const Size(2560, 1440);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final reported = FlutterError.onError;
  _reportedBeforeTheEditor = reported;
  FlutterError.onError = (details) {
    final text = details.exceptionAsString();
    if (_reportsOfTheTestFontAndTeardown.any(text.contains)) return;
    reported?.call(details);
  };
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (call) async => null,
  );
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: ShadApp(
      navigatorKey: appNavigatorKey,
      navigatorObservers: [mouseNavigationRouteObserver],
      home: const Scaffold(body: Text('library')),
    ),
  ));
}

Future<void> settleWithDisk(WidgetTester tester) async {
  for (var turn = 0; turn < 20; turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> leaveEditors(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final strategies = container.read(strategyProvider.notifier);
  switch (strategies.closeStrategy(asked: strategies.askedByTheUserNow())) {
    case Changed() || GaveWay():
      break;
  }
  appNavigatorKey.currentState!.popUntil((route) => route.isFirst);
  await settleWithDisk(tester);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
  FlutterError.onError = _reportedBeforeTheEditor;
}
