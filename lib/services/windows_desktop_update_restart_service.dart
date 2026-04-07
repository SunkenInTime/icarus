import 'dart:io';

import 'package:desktop_updater/desktop_updater.dart';
import 'package:path/path.dart' as path;

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
      processId: pid,
    );

    try {
      await Process.start(
        _resolvePowerShellExecutable(),
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptFile.path,
        ],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      if (await scriptFile.exists()) {
        await scriptFile.delete();
      }
      rethrow;
    }

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
        processId: processId,
      ),
      flush: true,
    );
    return scriptFile;
  }

  static String buildRestartScript({
    required String executablePath,
    required String installDirectory,
    required String updateDirectory,
    required int processId,
  }) {
    final normalizedExecutablePath =
        normalizeExecutablePath(executablePath) ?? executablePath.trim();
    final escapedExecutablePath =
        _escapePowerShellLiteral(normalizedExecutablePath);
    final escapedInstallDirectory = _escapePowerShellLiteral(installDirectory);
    final escapedUpdateDirectory = _escapePowerShellLiteral(updateDirectory);

    return '''
\$ErrorActionPreference = 'Stop'
\$trackedProcessId = $processId
\$executablePath = '$escapedExecutablePath'
\$installDirectory = '$escapedInstallDirectory'
\$updateDirectory = '$escapedUpdateDirectory'
\$scriptPath = \$MyInvocation.MyCommand.Path

try {
  for (\$attempt = 0; \$attempt -lt 120; \$attempt++) {
    \$process = Get-Process -Id \$trackedProcessId -ErrorAction SilentlyContinue
    if (\$null -eq \$process) {
      break
    }

    Start-Sleep -Milliseconds 500
  }

  \$process = Get-Process -Id \$trackedProcessId -ErrorAction SilentlyContinue
  if (\$null -ne \$process) {
    Stop-Process -Id \$trackedProcessId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    \$process = Get-Process -Id \$trackedProcessId -ErrorAction SilentlyContinue
    if (\$null -ne \$process) {
      exit 1
    }
  }

  if (Test-Path -LiteralPath \$updateDirectory) {
    \$updateItems = @(Get-ChildItem -LiteralPath \$updateDirectory -Force -ErrorAction SilentlyContinue)
    if (\$updateItems.Count -gt 0) {
      foreach (\$updateItem in \$updateItems) {
        Copy-Item -LiteralPath \$updateItem.FullName -Destination \$installDirectory -Recurse -Force
      }
    }
    Remove-Item -LiteralPath \$updateDirectory -Recurse -Force
  }

  Start-Process -FilePath \$executablePath -WorkingDirectory \$installDirectory
} finally {
  Remove-Item -LiteralPath \$scriptPath -Force -ErrorAction SilentlyContinue
}
''';
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

  static String _escapePowerShellLiteral(String value) {
    return value.replaceAll("'", "''");
  }

  static String? normalizeExecutablePath(String? executablePath) {
    final normalized = executablePath?.replaceAll('\u0000', '').trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }

    return normalized;
  }
}
