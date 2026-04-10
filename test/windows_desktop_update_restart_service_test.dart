import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/windows_desktop_update_restart_service.dart';

void main() {
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
        r'Start-Process -FilePath $executablePath -WorkingDirectory $installDirectory',
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
        contains(r'Write-Log "Updated executable launch command issued."'));
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
