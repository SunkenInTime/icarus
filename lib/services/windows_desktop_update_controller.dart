import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:desktop_updater/desktop_updater.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'package:icarus/services/windows_desktop_update_restart_service.dart';

class WindowsDesktopUpdateController extends ChangeNotifier {
  WindowsDesktopUpdateController({
    required Uri appArchiveUrl,
    this.localization,
    DesktopUpdater? updater,
    http.Client? httpClient,
    WindowsDesktopUpdateRestartService? restartService,
    bool autoCheck = true,
  })  : _appArchiveUrl = appArchiveUrl,
        _updater = updater ?? DesktopUpdater(),
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _restartService = restartService ??
            WindowsDesktopUpdateRestartService(updater: updater) {
    if (autoCheck) {
      unawaited(checkVersion());
    }
  }

  final Uri _appArchiveUrl;
  final DesktopUpdater _updater;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final WindowsDesktopUpdateRestartService _restartService;

  DesktopUpdateLocalization? localization;
  DesktopUpdateLocalization? get getLocalization => localization;

  String? _appName;
  String? get appName => _appName;

  String? _appVersion;
  String? get appVersion => _appVersion;

  bool _needUpdate = false;
  bool get needUpdate => _needUpdate;

  bool _isMandatory = false;
  bool get isMandatory => _isMandatory;

  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  bool _isDownloaded = false;
  bool get isDownloaded => _isDownloaded;

  double _downloadProgress = 0;
  double get downloadProgress => _downloadProgress;

  int _downloadSizeBytes = 0;
  double? get downloadSize => _downloadSizeBytes / 1024;

  int _downloadedBytes = 0;
  double get downloadedSize => _downloadedBytes / 1024;

  List<ChangeModel?>? _releaseNotes;
  List<ChangeModel?>? get releaseNotes => _releaseNotes;

  bool _skipUpdate = false;
  bool get skipUpdate => _skipUpdate;

  ItemModel? _availableUpdate;

  @override
  void dispose() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
    super.dispose();
  }

  void makeSkipUpdate() {
    _skipUpdate = true;
    notifyListeners();
  }

  Future<void> checkVersion() async {
    try {
      final versionResponse = await _updater.versionCheck(
        appArchiveUrl: _appArchiveUrl.toString(),
      );

      if (versionResponse == null) {
        return;
      }

      final files = _requiredChangedFiles(versionResponse);
      _availableUpdate = versionResponse;
      _needUpdate = true;
      _isMandatory = versionResponse.mandatory;
      _releaseNotes = versionResponse.changes.cast<ChangeModel?>();
      _appName = versionResponse.appName;
      _appVersion = versionResponse.version;
      _downloadSizeBytes = files.fold<int>(
        0,
        (int total, FileHashModel file) => total + file.length,
      );
      notifyListeners();
    } catch (_) {
      // Leave the direct installer updater silent if the remote metadata fails.
    }
  }

  Future<void> downloadUpdate() async {
    if (_isDownloading) {
      return;
    }

    final update = _availableUpdate;
    if (update == null) {
      throw StateError('No desktop update is available to download.');
    }

    final files = _requiredChangedFiles(update);
    if (files.isEmpty) {
      throw StateError('The desktop update did not include any changed files.');
    }

    final installDirectory = await _resolveInstallDirectory();
    final updateDirectory = Directory(path.join(installDirectory, 'update'));
    await _resetUpdateDirectory(updateDirectory);

    _skipUpdate = false;
    _isDownloading = true;
    _isDownloaded = false;
    _downloadProgress = 0;
    _downloadedBytes = 0;
    notifyListeners();

    try {
      var completedBytes = 0;
      for (final file in files) {
        await _downloadFileWithRetry(
          remoteFolder: update.url,
          file: file,
          updateDirectory: updateDirectory,
          completedBytes: completedBytes,
          totalBytes: _downloadSizeBytes,
        );
        completedBytes += file.length;
        _downloadedBytes = completedBytes;
        _downloadProgress =
            _calculateProgress(_downloadedBytes, _downloadSizeBytes);
        notifyListeners();
      }

      await _verifyStagedFiles(
        updateDirectory: updateDirectory,
        files: files,
      );

      _isDownloaded = true;
    } catch (_) {
      _isDownloaded = false;
      await _cleanupPartialDownload(updateDirectory);
      rethrow;
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  Future<void> restartApp() async {
    final update = _availableUpdate;
    if (update == null) {
      throw StateError('No desktop update is available to apply.');
    }

    await _restartService.restartIntoDownloadedUpdate(
      expectedFiles: _requiredChangedFiles(update),
    );
  }

  Future<void> _downloadFileWithRetry({
    required String remoteFolder,
    required FileHashModel file,
    required Directory updateDirectory,
    required int completedBytes,
    required int totalBytes,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 0; attempt < 3; attempt++) {
      final destination = _stagedFile(updateDirectory.path, file.filePath);
      try {
        await _downloadSingleFile(
          remoteFolder: remoteFolder,
          file: file,
          destination: destination,
          completedBytes: completedBytes,
          totalBytes: totalBytes,
        );
        await _verifyDownloadedFile(destination, file);
        return;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (await destination.exists()) {
          await destination.delete();
        }
        if (attempt < 2) {
          await Future<void>.delayed(
              Duration(milliseconds: 400 * (attempt + 1)));
        }
      }
    }

    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<void> _downloadSingleFile({
    required String remoteFolder,
    required FileHashModel file,
    required File destination,
    required int completedBytes,
    required int totalBytes,
  }) async {
    final request = http.Request(
      'GET',
      buildRemoteFileUrl(remoteFolder, file.filePath),
    );
    final response = await _httpClient.send(request);
    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to download ${file.filePath} (HTTP ${response.statusCode}).',
      );
    }

    await destination.parent.create(recursive: true);
    final sink = destination.openWrite();
    var fileBytesReceived = 0;

    try {
      await response.stream.listen(
        (List<int> chunk) {
          sink.add(chunk);
          fileBytesReceived += chunk.length;
          _downloadedBytes = completedBytes + fileBytesReceived;
          _downloadProgress = _calculateProgress(_downloadedBytes, totalBytes);
          notifyListeners();
        },
        onDone: () async {
          await sink.close();
        },
        onError: (Object error) async {
          await sink.close();
          throw error;
        },
        cancelOnError: true,
      ).asFuture<void>();
    } catch (_) {
      await sink.close();
      rethrow;
    }
  }

  Future<void> _verifyStagedFiles({
    required Directory updateDirectory,
    required List<FileHashModel> files,
  }) async {
    for (final file in files) {
      await _verifyDownloadedFile(
        _stagedFile(updateDirectory.path, file.filePath),
        file,
      );
    }
  }

  Future<void> _verifyDownloadedFile(
    File stagedFile,
    FileHashModel expectedFile,
  ) async {
    if (!await stagedFile.exists()) {
      throw FileSystemException(
        'Downloaded update is missing ${expectedFile.filePath}.',
        stagedFile.path,
      );
    }

    final actualLength = await stagedFile.length();
    if (actualLength != expectedFile.length) {
      throw FileSystemException(
        'Downloaded update length mismatch for ${expectedFile.filePath}.',
        stagedFile.path,
      );
    }

    final actualHash = await _getFileHash(stagedFile);
    if (actualHash != expectedFile.calculatedHash) {
      throw FileSystemException(
        'Downloaded update hash mismatch for ${expectedFile.filePath}.',
        stagedFile.path,
      );
    }
  }

  Future<String> _resolveInstallDirectory() async {
    final executablePath =
        WindowsDesktopUpdateRestartService.normalizeExecutablePath(
            await _updater.getExecutablePath());
    if (executablePath == null || executablePath.isEmpty) {
      throw const FileSystemException(
        'Unable to resolve the installed executable path.',
      );
    }

    return File(executablePath).parent.path;
  }

  Future<void> _resetUpdateDirectory(Directory updateDirectory) async {
    if (await updateDirectory.exists()) {
      await updateDirectory.delete(recursive: true);
    }
    await updateDirectory.create(recursive: true);
  }

  Future<void> _cleanupPartialDownload(Directory updateDirectory) async {
    if (await updateDirectory.exists()) {
      await updateDirectory.delete(recursive: true);
    }
    _downloadedBytes = 0;
    _downloadProgress = 0;
  }

  List<FileHashModel> _requiredChangedFiles(ItemModel update) {
    return (update.changedFiles ?? const <FileHashModel?>[])
        .whereType<FileHashModel>()
        .toList();
  }

  File _stagedFile(String updateDirectory, String relativePath) {
    return File(
      path.joinAll(
        <String>[
          updateDirectory,
          ...splitRelativePath(relativePath),
        ],
      ),
    );
  }

  static Uri buildRemoteFileUrl(String remoteFolder, String relativePath) {
    final baseUri = Uri.parse(remoteFolder);
    return baseUri.replace(
      pathSegments: <String>[
        ...baseUri.pathSegments.where((String segment) => segment.isNotEmpty),
        ...splitRelativePath(relativePath),
      ],
    );
  }

  static List<String> splitRelativePath(String relativePath) {
    return relativePath
        .split(RegExp(r'[\\\/]+'))
        .where((String segment) => segment.isNotEmpty)
        .toList();
  }

  static double _calculateProgress(int receivedBytes, int totalBytes) {
    if (totalBytes <= 0) {
      return 0;
    }

    final progress = receivedBytes / totalBytes;
    return progress.clamp(0, 1).toDouble();
  }

  static Future<String> _getFileHash(File file) async {
    final bytes = await file.readAsBytes();
    final hash = await Blake2b().hash(bytes);
    return base64Encode(hash.bytes);
  }
}
