import 'dart:io';

import 'package:flutter/material.dart' show Size;
import 'package:icarus/const/second_instance_args.dart';
import 'package:icarus/startup/windows_process_termination.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

bool get isWindowsRuntime => Platform.isWindows;

Future<void> ensureIcarusSingleInstance(
  List<String> args, {
  required String instanceId,
}) async {
  if (!Platform.isWindows) {
    return;
  }

  await WindowsSingleInstance.ensureSingleInstance(
    args,
    instanceId,
    onSecondWindow: publishSecondInstanceArgs,
    exitFunction: terminateDuplicateWindowsProcess,
  );
}

Future<void> initializeIcarusDesktopWindow(String title) async {
  await windowManager.ensureInitialized();
  final windowOptions = WindowOptions(
    size: const Size(1600, 900),
    minimumSize: const Size(1280, 720),
    center: true,
    title: title,
    // The app draws its own title strip (lib/widgets/window_chrome.dart).
    // macOS keeps its traffic lights; Windows and Linux get app-drawn
    // caption buttons.
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: true,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
