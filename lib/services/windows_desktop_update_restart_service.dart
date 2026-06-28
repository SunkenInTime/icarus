import 'dart:io';

import 'package:desktop_updater/desktop_updater.dart';
import 'package:path/path.dart' as path;

import 'package:icarus/services/app_error_reporter.dart';

class WindowsDesktopUpdateRestartService {
  WindowsDesktopUpdateRestartService({
    DesktopUpdater? updater,
  }) : _updater = updater ?? DesktopUpdater();

  final DesktopUpdater _updater;

  Future<void> restartIntoDownloadedUpdate({
    List<FileHashModel> expectedFiles = const <FileHashModel>[],
  }) async {
    if (!Platform.isWindows) {
      await _updater.restartApp();
      return;
    }

    final executablePath = normalizeExecutablePath(
      await _updater.getExecutablePath(),
    );
    if (executablePath == null || executablePath.isEmpty) {
      throw const FileSystemException(
        'Unable to resolve the installed executable path.',
      );
    }

    final installDirectory = File(executablePath).parent.path;
    final updateDirectory = path.join(installDirectory, 'update');
    final updaterLogPath = resolveUpdaterLogPath();
    final launcherLogPath = resolveLauncherLogPath();
    final updateFolder = Directory(updateDirectory);
    if (!await updateFolder.exists()) {
      throw FileSystemException(
        'Downloaded desktop update folder was not found.',
        updateDirectory,
      );
    }

    await _verifyExpectedFiles(
      updateDirectory: updateDirectory,
      expectedFiles: expectedFiles,
    );

    final scriptFile = await _writeRestartScript(
      executablePath: executablePath,
      installDirectory: installDirectory,
      updateDirectory: updateDirectory,
      logPath: updaterLogPath,
      processId: pid,
    );
    final launcherFile = await _writeLauncherScript(
      powerShellExecutable: _resolvePowerShellExecutable(),
      scriptPath: scriptFile.path,
      launcherLogPath: launcherLogPath,
    );
    final commandExecutable = _resolveCommandExecutable();
    _reportInfoSafely(
      'Starting detached desktop update launcher.',
      source: 'WindowsDesktopUpdateRestartService.restartIntoDownloadedUpdate',
      error: <String, String>{
        'command': commandExecutable,
        'launcherPath': launcherFile.path,
        'scriptPath': scriptFile.path,
        'updaterLogPath': updaterLogPath,
        'launcherLogPath': launcherLogPath,
        'installDirectory': installDirectory,
        'updateDirectory': updateDirectory,
      },
    );

    try {
      await Process.start(
        commandExecutable,
        <String>[
          '/c',
          launcherFile.path,
        ],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      if (await scriptFile.exists()) {
        await scriptFile.delete();
      }
      if (await launcherFile.exists()) {
        await launcherFile.delete();
      }
      rethrow;
    }

    await Future<void>.delayed(const Duration(milliseconds: 250));
    exit(0);
  }

  Future<void> _verifyExpectedFiles({
    required String updateDirectory,
    required List<FileHashModel> expectedFiles,
  }) async {
    for (final file in expectedFiles) {
      final stagedFile = File(
        path.joinAll(
          <String>[
            updateDirectory,
            ..._splitRelativePath(file.filePath),
          ],
        ),
      );
      if (!await stagedFile.exists()) {
        throw FileSystemException(
          'Downloaded update is missing ${file.filePath}.',
          stagedFile.path,
        );
      }
    }
  }

  Future<File> _writeRestartScript({
    required String executablePath,
    required String installDirectory,
    required String updateDirectory,
    required String logPath,
    required int processId,
  }) async {
    final scriptPath = path.join(
      Directory.systemTemp.path,
      'icarus_apply_update_${processId}_${DateTime.now().microsecondsSinceEpoch}.ps1',
    );
    final scriptFile = File(scriptPath);
    await scriptFile.writeAsString(
      buildRestartScript(
        executablePath: executablePath,
        installDirectory: installDirectory,
        updateDirectory: updateDirectory,
        logPath: logPath,
        processId: processId,
      ),
      flush: true,
    );
    return scriptFile;
  }

  Future<File> _writeLauncherScript({
    required String powerShellExecutable,
    required String scriptPath,
    required String launcherLogPath,
  }) async {
    final launcherPath = path.join(
      Directory.systemTemp.path,
      'icarus_launch_update_${pid}_${DateTime.now().microsecondsSinceEpoch}.cmd',
    );
    final launcherFile = File(launcherPath);
    await launcherFile.writeAsString(
      buildLauncherScript(
        powerShellExecutable: powerShellExecutable,
        scriptPath: scriptPath,
        launcherLogPath: launcherLogPath,
      ),
      flush: true,
    );
    return launcherFile;
  }

  static String buildLauncherScript({
    required String powerShellExecutable,
    required String scriptPath,
    required String launcherLogPath,
  }) {
    final escapedPowerShellExecutable =
        _escapeBatchQuotedValue(powerShellExecutable);
    final escapedScriptPath = _escapeBatchQuotedValue(scriptPath);
    final escapedLauncherLogPath = _escapeBatchQuotedValue(launcherLogPath);

    return '''
@echo off
setlocal EnableExtensions
set "PS_EXECUTABLE=$escapedPowerShellExecutable"
set "UPDATER_SCRIPT=$escapedScriptPath"
set "LAUNCHER_LOG=$escapedLauncherLogPath"
for %%I in ("%LAUNCHER_LOG%") do if not exist "%%~dpI" mkdir "%%~dpI"
>> "%LAUNCHER_LOG%" echo [%date% %time%] Launcher started. script="%UPDATER_SCRIPT%"
start "" /min "%PS_EXECUTABLE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%UPDATER_SCRIPT%"
set "START_EXIT_CODE=%errorlevel%"
>> "%LAUNCHER_LOG%" echo [%date% %time%] Launcher finished with exitCode=%START_EXIT_CODE%
del "%~f0" >nul 2>&1
''';
  }

  static String buildRestartScript({
    required String executablePath,
    required String installDirectory,
    required String updateDirectory,
    required String logPath,
    required int processId,
  }) {
    final normalizedExecutablePath =
        normalizeExecutablePath(executablePath) ?? executablePath.trim();
    final escapedExecutablePath =
        _escapePowerShellLiteral(normalizedExecutablePath);
    final escapedInstallDirectory = _escapePowerShellLiteral(installDirectory);
    final escapedUpdateDirectory = _escapePowerShellLiteral(updateDirectory);
    final escapedLogPath = _escapePowerShellLiteral(logPath);

    return '''
\$ErrorActionPreference = 'Stop'
\$trackedProcessId = $processId
\$executablePath = '$escapedExecutablePath'
\$installDirectory = '$escapedInstallDirectory'
\$updateDirectory = '$escapedUpdateDirectory'
\$logPath = '$escapedLogPath'
\$scriptPath = \$MyInvocation.MyCommand.Path
\$deleteScriptOnExit = \$true

function Write-Log {
  param([string]\$Message)
  \$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
  \$line = "[\$timestamp] \$Message"
  \$logDirectory = Split-Path -Parent \$logPath
  if (-not [string]::IsNullOrWhiteSpace(\$logDirectory) -and -not (Test-Path -LiteralPath \$logDirectory)) {
    New-Item -ItemType Directory -Path \$logDirectory -Force | Out-Null
  }
  Add-Content -LiteralPath \$logPath -Value \$line -Encoding UTF8
}

try {
  Write-Log "Updater script started. scriptPath=\$scriptPath"
  Write-Log "Executable path: \$executablePath"
  Write-Log "Install directory: \$installDirectory"
  Write-Log "Update directory: \$updateDirectory"

  for (\$attempt = 0; \$attempt -lt 120; \$attempt++) {
    \$process = Get-Process -Id \$trackedProcessId -ErrorAction SilentlyContinue
    if (\$null -eq \$process) {
      Write-Log "Tracked process exited after \$attempt polling attempts."
      break
    }

    Start-Sleep -Milliseconds 500
  }

  \$process = Get-Process -Id \$trackedProcessId -ErrorAction SilentlyContinue
  if (\$null -ne \$process) {
    Write-Log "Tracked process still running. Attempting forced stop."
    Stop-Process -Id \$trackedProcessId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    \$process = Get-Process -Id \$trackedProcessId -ErrorAction SilentlyContinue
    if (\$null -ne \$process) {
      Write-Log "Tracked process could not be terminated. Aborting update apply."
      throw "Tracked process \$trackedProcessId could not be terminated."
    }
  }

  if (Test-Path -LiteralPath \$updateDirectory) {
    \$updateItems = @(Get-ChildItem -LiteralPath \$updateDirectory -Force -ErrorAction SilentlyContinue)
    Write-Log "Found \$((\$updateItems | Measure-Object).Count) staged update item(s)."
    if (\$updateItems.Count -gt 0) {
      foreach (\$updateItem in \$updateItems) {
        Write-Log "Copying \$((\$updateItem.FullName)) to \$installDirectory"
        Copy-Item -LiteralPath \$updateItem.FullName -Destination \$installDirectory -Recurse -Force
      }
    }
    Write-Log "Removing staged update directory."
    Remove-Item -LiteralPath \$updateDirectory -Recurse -Force
  } else {
    Write-Log "Staged update directory was missing when script started."
  }

  Write-Log "Launching updated executable."
  \$startedProcess = \$null
  for (\$launchAttempt = 1; \$launchAttempt -le 10; \$launchAttempt++) {
    try {
      \$startedProcess = Start-Process -FilePath \$executablePath -WorkingDirectory \$installDirectory -PassThru
      Write-Log "Updated executable launch command issued on attempt \$launchAttempt with pid \$((\$startedProcess.Id))."
    } catch {
      Write-Log "Launch attempt \$launchAttempt failed: \$((\$_.Exception.Message))"
    }

    if (\$null -ne \$startedProcess) {
      Start-Sleep -Milliseconds 400
      \$confirmedProcess = Get-Process -Id \$startedProcess.Id -ErrorAction SilentlyContinue
      if (\$null -ne \$confirmedProcess) {
        Write-Log "Updated executable confirmed running with pid \$((\$confirmedProcess.Id))."
        break
      }

      Write-Log "Launch attempt \$launchAttempt exited before confirmation."
      \$startedProcess = \$null
    }

    Start-Sleep -Milliseconds 600
  }

  if (\$null -eq \$startedProcess) {
    throw 'Updated executable did not remain running after launch attempts.'
  }
} catch {
  \$deleteScriptOnExit = \$false
  Write-Log ("ERROR: " + \$_.Exception.Message)
  Write-Log "Preserving updater script for inspection at \$scriptPath"
  throw
} finally {
  Write-Log "Updater script exiting. deleteScriptOnExit=\$deleteScriptOnExit"
  if (\$deleteScriptOnExit) {
    Remove-Item -LiteralPath \$scriptPath -Force -ErrorAction SilentlyContinue
  }
}
''';
  }

  static String resolveUpdaterLogPath() {
    final supportDirectory = AppErrorReporter.applicationSupportDirectoryPath;
    if (supportDirectory != null && supportDirectory.trim().isNotEmpty) {
      return path.join(supportDirectory, 'windows_desktop_updater.log');
    }

    return path.join(
      Directory.systemTemp.path,
      'icarus_windows_desktop_updater.log',
    );
  }

  static String resolveLauncherLogPath() {
    final supportDirectory = AppErrorReporter.applicationSupportDirectoryPath;
    if (supportDirectory != null && supportDirectory.trim().isNotEmpty) {
      return path.join(supportDirectory, 'windows_desktop_updater_launcher.log');
    }

    return path.join(
      Directory.systemTemp.path,
      'icarus_windows_desktop_updater_launcher.log',
    );
  }

  static List<String> _splitRelativePath(String filePath) {
    return filePath
        .split(RegExp(r'[\\\/]+'))
        .where((segment) => segment.isNotEmpty)
        .toList();
  }

  static String _resolvePowerShellExecutable() {
    final systemRoot = Platform.environment['SystemRoot'];
    if (systemRoot == null || systemRoot.isEmpty) {
      return 'powershell';
    }

    return path.join(
      systemRoot,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }

  static String _resolveCommandExecutable() {
    final systemRoot = Platform.environment['SystemRoot'];
    if (systemRoot == null || systemRoot.isEmpty) {
      return 'cmd';
    }

    return path.join(
      systemRoot,
      'System32',
      'cmd.exe',
    );
  }

  static String _escapePowerShellLiteral(String value) {
    return value.replaceAll("'", "''");
  }

  static String _escapeBatchQuotedValue(String value) {
    return value.replaceAll('"', '""').replaceAll('%', '%%');
  }

  static String? normalizeExecutablePath(String? executablePath) {
    final normalized = executablePath?.replaceAll('\u0000', '').trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }

    return normalized;
  }

  void _reportInfoSafely(
    String message, {
    required String source,
    Object? error,
  }) {
    try {
      AppErrorReporter.reportInfo(
        message,
        source: source,
        error: error,
      );
    } catch (_) {
      // Logging must never interrupt the update flow.
    }
  }
}
