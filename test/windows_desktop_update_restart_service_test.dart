import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/windows_desktop_update_restart_service.dart';

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

  test('normalizeExecutablePath strips plugin null terminator', () {
    expect(
      WindowsDesktopUpdateRestartService.normalizeExecutablePath(
        'C:\\Users\\Alice\\Icarus\\icarus.exe\u0000',
      ),
      r'C:\Users\Alice\Icarus\icarus.exe',
    );
  });
}
