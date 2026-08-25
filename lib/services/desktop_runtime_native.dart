import 'dart:io';

import 'package:icarus/const/second_instance_args.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

bool get isWindowsRuntime => Platform.isWindows;

Future<void> ensureIcarusSingleInstance(List<String> args) async {
  if (!Platform.isWindows) {
    return;
  }

  await WindowsSingleInstance.ensureSingleInstance(
    args,
    'icarus_single_instance',
    onSecondWindow: publishSecondInstanceArgs,
  );
}

Future<void> initializeIcarusDesktopWindow(String title) async {
  await windowManager.ensureInitialized();
  final windowOptions = WindowOptions(title: title);
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
