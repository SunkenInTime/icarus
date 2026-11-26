import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';
import 'package:icarus/strategy/open_seen.dart';

const _reportsOfTheTestFontAndTeardown = [
  'overflowed',
  'Cannot get renderObject of inactive element',
];

FlutterExceptionHandler? _reportedBeforeTheEditor;

late BuildContext libraryContext;
late WidgetRef libraryRef;

Future<List<MethodCall>> pumpLibraryWithEditors(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final windowCalls = <MethodCall>[];
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
    (call) async {
      windowCalls.add(call);
      return null;
    },
  );
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: ToastificationWrapper(
        child: ShadApp(
      navigatorKey: appNavigatorKey,
      navigatorObservers: [mouseNavigationRouteObserver],
      home: Scaffold(
        body: Consumer(builder: (context, ref, _) {
          libraryContext = context;
          libraryRef = ref;
          return const Text('library');
        }),
      ),
    )),
  ));
  return windowCalls;
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
  await settleWithDisk(tester);
  FlutterError.onError = _reportedBeforeTheEditor;
}

Future<void> closeHive(WidgetTester tester) async {
  var closed = false;
  final closing = Hive.close().whenComplete(() => closed = true);
  for (var turn = 0; turn < 50 && !closed; turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(closed, isTrue);
  await closing;
}
