import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/windows_desktop_update_restart_service.dart';

void main() {
  test('restart script uses absolute install paths and working directory', () {
    final script = WindowsDesktopUpdateRestartService.buildRestartScript(
      executablePath: r"C:\Users\Alice\App's\Icarus\icarus.exe",
      installDirectory: r"C:\Users\Alice\App's\Icarus",
      updateDirectory: r"C:\Users\Alice\App's\Icarus\update",
      processId: 4242,
    );

    expect(script, contains(r"$trackedProcessId = 4242"));
    expect(
      script,
      contains(r"$executablePath = 'C:\Users\Alice\App''s\Icarus\icarus.exe'"),
    );
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
    expect(script, isNot(contains(r'xcopy /E /I /Y "update\*" "."')));
  });
}
