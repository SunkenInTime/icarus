import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/windows_desktop_update_restart_service.dart';
import 'package:path/path.dart' as path;

void main() {
  test('launcher script records handoff and starts powershell via cmd', () {
    final script = WindowsDesktopUpdateRestartService.buildLauncherScript(
      powerShellExecutable:
          r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      scriptPath: r"C:\Users\Alice\App's\Temp\icarus_apply_update.ps1",
      launcherLogPath:
          r"C:\Users\Alice\AppData\Roaming\Icarus\windows_desktop_updater_launcher.log",
    );

    expect(
      script,
      contains(
        r'set "PS_EXECUTABLE=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"',
      ),
    );
    expect(
      script,
      contains(
        'set "UPDATER_SCRIPT=C:\\Users\\Alice\\App\'s\\Temp\\icarus_apply_update.ps1"',
      ),
    );
    expect(
      script,
      contains(
        r'set "LAUNCHER_LOG=C:\Users\Alice\AppData\Roaming\Icarus\windows_desktop_updater_launcher.log"',
      ),
    );
    expect(
      script,
      contains(
        r'start "" /min "%PS_EXECUTABLE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%UPDATER_SCRIPT%"',
      ),
    );
    expect(script, contains(r'del "%~f0" >nul 2>&1'));
  });

  test('restart script uses absolute install paths and working directory', () {
    final script = WindowsDesktopUpdateRestartService.buildRestartScript(
      executablePath: "C:\\Users\\Alice\\App's\\Icarus\\icarus.exe\u0000",
      installDirectory: r"C:\Users\Alice\App's\Icarus",
      updateDirectory: r"C:\Users\Alice\App's\Icarus\update",
      logPath:
          r"C:\Users\Alice\AppData\Roaming\Icarus\windows_desktop_updater.log",
      processId: 4242,
    );

    expect(script, contains(r"$trackedProcessId = 4242"));
    expect(
      script,
      contains(r"$executablePath = 'C:\Users\Alice\App''s\Icarus\icarus.exe'"),
    );
    expect(script, isNot(contains('\u0000')));
    expect(
      script,
      contains(r"$installDirectory = 'C:\Users\Alice\App''s\Icarus'"),
    );
    expect(
      script,
      contains(r"$updateDirectory = 'C:\Users\Alice\App''s\Icarus\update'"),
    );
    expect(
      script,
      contains(
        r"$logPath = 'C:\Users\Alice\AppData\Roaming\Icarus\windows_desktop_updater.log'",
      ),
    );
    expect(
      script,
      contains(
        r'$startedProcess = Start-Process -FilePath $executablePath -WorkingDirectory $installDirectory -PassThru',
      ),
    );
    expect(
      script,
      contains(r'for ($launchAttempt = 1; $launchAttempt -le 10; $launchAttempt++) {'),
    );
    expect(
      script,
      contains(
        r'Write-Log "Updated executable confirmed running with pid $(($confirmedProcess.Id))."',
      ),
    );
    expect(
      script,
      contains(
        "throw 'Updated executable did not remain running after launch attempts.'",
      ),
    );
    expect(
      script,
      contains(
        r'$updateItems = @(Get-ChildItem -LiteralPath $updateDirectory -Force -ErrorAction SilentlyContinue)',
      ),
    );
    expect(
      script,
      contains(
        r'foreach ($updateItem in $updateItems) {',
      ),
    );
    expect(
      script,
      contains(
        r'Copy-Item -LiteralPath $updateItem.FullName -Destination $installDirectory -Recurse -Force',
      ),
    );
    expect(
      script,
      contains(
        r'Stop-Process -Id $trackedProcessId -Force -ErrorAction SilentlyContinue',
      ),
    );
    expect(script, contains('try {'));
    expect(script, contains('} finally {'));
    expect(
      script,
      contains(
        r'Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue',
      ),
    );
    expect(script, contains('function Write-Log {'));
    expect(
        script,
        contains(
            r'Write-Log "Updater script started. scriptPath=$scriptPath"'));
    expect(script,
        contains(r'Write-Log "Updated executable launch command issued on attempt $launchAttempt with pid $(($startedProcess.Id))."'));
    expect(script, contains(r'Write-Log ("ERROR: " + $_.Exception.Message)'));
    expect(
        script,
        contains(
            r'Write-Log "Preserving updater script for inspection at $scriptPath"'));
    expect(
        script,
        contains(
            r'Write-Log "Updater script exiting. deleteScriptOnExit=$deleteScriptOnExit"'));
    expect(script, isNot(contains(r'xcopy /E /I /Y "update\*" "."')));
  });

  group('splitRelativePath', () {
    test('accepts the file paths a release lists', () {
      expect(
        WindowsDesktopUpdateRestartService.splitRelativePath('icarus.exe'),
        <String>['icarus.exe'],
      );
      expect(
        WindowsDesktopUpdateRestartService.splitRelativePath(
          r'data\flutter_assets\AssetManifest.bin',
        ),
        <String>['data', 'flutter_assets', 'AssetManifest.bin'],
      );
      expect(
        WindowsDesktopUpdateRestartService.splitRelativePath(
          'ffmpeg/avcodec-61.dll',
        ),
        <String>['ffmpeg', 'avcodec-61.dll'],
      );
    });

    for (final unsafePath in <String>[
      r'..\..\escaped.txt',
      r'data\..\..\escaped.txt',
      '../escaped.txt',
      r'.\icarus.exe',
      r'... \escaped.txt',
      r'C:\Windows\escaped.txt',
      'C:escaped.txt',
      r'\Windows\escaped.txt',
      '/etc/escaped.txt',
      r'\\server\share\escaped.txt',
      r'data\\escaped.txt',
      r'data\',
      '',
    ]) {
      test('refuses "$unsafePath"', () {
        expect(
          () =>
              WindowsDesktopUpdateRestartService.splitRelativePath(unsafePath),
          throwsA(isA<FileSystemException>()),
        );
      });
    }
  });

  test(
    'restart script copies the update and relaunches when its log cannot be '
    'written',
    () async {
      final root =
          await Directory.systemTemp.createTemp('icarus_restart_script_');
      addTearDown(() async {
        // The relaunched stand-in app may still hold its folder for a moment.
        for (var attempt = 0; attempt < 10; attempt++) {
          try {
            await root.delete(recursive: true);
            return;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
        }
      });

      final installDirectory = Directory(path.join(root.path, 'install'))
        ..createSync();
      final updateDirectory =
          Directory(path.join(installDirectory.path, 'update'))..createSync();
      File(path.join(installDirectory.path, 'payload.txt'))
          .writeAsStringSync('old');
      File(path.join(updateDirectory.path, 'payload.txt'))
          .writeAsStringSync('new');

      // Stands in for the app: records that it was launched, then stays up
      // long enough for the script to confirm it is running.
      final relaunchMarker = File(path.join(root.path, 'relaunched.txt'));
      final app = File(path.join(installDirectory.path, 'app.cmd'))
        ..writeAsStringSync(
          '@echo off\r\n'
          'echo relaunched> "${relaunchMarker.path}"\r\n'
          'ping -n 3 127.0.0.1 >nul\r\n',
        );

      // A folder where the log file should be, so every log write fails.
      final logPath = path.join(root.path, 'updater.log');
      Directory(logPath).createSync();

      // The script waits for the app it replaces to exit; this one already has.
      final exitedApp = await Process.start('cmd', <String>['/c', 'exit']);
      await exitedApp.exitCode;

      final script = File(path.join(root.path, 'apply_update.ps1'))
        ..writeAsStringSync(
          WindowsDesktopUpdateRestartService.buildRestartScript(
            executablePath: app.path,
            installDirectory: installDirectory.path,
            updateDirectory: updateDirectory.path,
            logPath: logPath,
            processId: exitedApp.pid,
          ),
        );

      final result = await Process.run('powershell', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(
        File(path.join(installDirectory.path, 'payload.txt'))
            .readAsStringSync(),
        'new',
      );
      expect(updateDirectory.existsSync(), isFalse);
      for (var attempt = 0;
          attempt < 50 && !relaunchMarker.existsSync();
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(relaunchMarker.existsSync(), isTrue);
    },
    skip: Platform.isWindows ? false : 'runs the script in Windows PowerShell',
  );
}
