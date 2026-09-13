import 'dart:async';
import 'dart:io';

import 'package:win32/win32.dart';

Future<void> terminateDuplicateWindowsProcess() {
  if (!Platform.isWindows) {
    throw UnsupportedError('Windows process termination requires Windows.');
  }

  // flutter_inappwebview_windows can crash in DLL_PROCESS_DETACH while
  // releasing static WinRT state. This runs after argument forwarding and
  // before Hive opens, so skipping DLL cleanup cannot interrupt library writes.
  // See https://github.com/pichillilorenzo/flutter_inappwebview/issues/2733.
  final result = TerminateProcess(GetCurrentProcess(), 0);
  if (result == 0) {
    throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
  }

  // Keep startup suspended until Windows finishes terminating the process.
  return Completer<void>().future;
}
