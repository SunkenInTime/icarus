import 'dart:convert';
import 'dart:io';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:desktop_updater/desktop_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/windows_desktop_update_controller.dart';

void main() {
  test('buildRemoteFileUrl normalizes Windows relative paths', () {
    final uri = WindowsDesktopUpdateController.buildRemoteFileUrl(
      'https://example.com/updates/windows/stable/4.0.5%2B59-windows',
      r'data\flutter_assets\Asset Manifest.bin',
    );

    expect(
      uri.toString(),
      'https://example.com/updates/windows/stable/4.0.5+59-windows/data/flutter_assets/Asset%20Manifest.bin',
    );
  });

  test('downloadUpdate retries failed files and stages every expected file',
      () async {
    final installDirectory =
        await Directory.systemTemp.createTemp('icarus_update_install_');
    final executablePath = '${installDirectory.path}\\icarus.exe';
    await File(executablePath).writeAsBytes(utf8.encode('old exe'));

    final remoteFiles = <String, List<int>>{
      'icarus.exe': utf8.encode('new exe bytes'),
      r'data\flutter_assets\AssetManifest.bin': utf8.encode('asset manifest'),
      'window_manager_plugin.dll': utf8.encode('window manager plugin'),
    };

    final requestCounts = <String, int>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      if (await installDirectory.exists()) {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await installDirectory.delete(recursive: true);
        } on PathAccessException {
          // Windows can briefly hold temp file handles after the final read.
        }
      }
    });

    server.listen((HttpRequest request) async {
      final relativePath = request.uri.pathSegments.skip(1).join('/');
      requestCounts[relativePath] = (requestCounts[relativePath] ?? 0) + 1;

      if (relativePath == 'icarus.exe' && requestCounts[relativePath] == 1) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
        return;
      }

      final fileBytes = remoteFiles[relativePath.replaceAll('/', r'\')] ??
          remoteFiles[relativePath];
      if (fileBytes == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = fileBytes.length;
      request.response.add(fileBytes);
      await request.response.close();
    });

    final changedFiles = await Future.wait<FileHashModel>(
      remoteFiles.entries.map((MapEntry<String, List<int>> entry) async {
        return FileHashModel(
          filePath: entry.key,
          calculatedHash: await _hashBytes(entry.value),
          length: entry.value.length,
        );
      }),
    );

    final update = ItemModel(
      version: '4.0.5+59',
      shortVersion: 59,
      changes: <ChangeModel>[
        ChangeModel(message: 'Test release'),
      ],
      date: '2026-03-20',
      mandatory: false,
      url: 'http://${server.address.host}:${server.port}/updates',
      platform: 'windows',
      changedFiles: changedFiles,
      appName: 'Icarus',
    );

    final controller = WindowsDesktopUpdateController(
      appArchiveUrl: Uri.parse('https://example.com/app-archive.json'),
      updater: _FakeDesktopUpdater(
        executablePath: '$executablePath\u0000',
        update: update,
      ),
      autoCheck: false,
    );
    addTearDown(controller.dispose);

    await controller.checkVersion();
    expect(controller.needUpdate, isTrue);

    await controller.downloadUpdate();

    for (final file in changedFiles) {
      final stagedFile = File(
        [
          installDirectory.path,
          'update',
          ...WindowsDesktopUpdateController.splitRelativePath(file.filePath),
        ].join(Platform.pathSeparator),
      );
      expect(await stagedFile.exists(), isTrue);
      expect(await stagedFile.readAsBytes(), remoteFiles[file.filePath]);
    }

    expect(controller.isDownloaded, isTrue);
    expect(controller.downloadProgress, 1);
    expect(requestCounts['icarus.exe'], 2);
  });

  test('downloadUpdate preserves verification errors during cleanup', () async {
    final installDirectory =
        await Directory.systemTemp.createTemp('icarus_update_cleanup_');
    final executablePath = '${installDirectory.path}\\icarus.exe';
    await File(executablePath).writeAsBytes(utf8.encode('old exe'));
    addTearDown(() async {
      if (await installDirectory.exists()) {
        await installDirectory.delete(recursive: true);
      }
    });

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    final fileBytes = utf8.encode('corrupted payload');
    server.listen((HttpRequest request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = fileBytes.length;
      request.response.add(fileBytes);
      await request.response.close();
    });

    final update = ItemModel(
      version: '4.0.6+60',
      shortVersion: 60,
      changes: <ChangeModel>[
        ChangeModel(message: 'Cleanup regression test'),
      ],
      date: '2026-04-10',
      mandatory: false,
      url: 'http://${server.address.host}:${server.port}/updates',
      platform: 'windows',
      changedFiles: <FileHashModel>[
        FileHashModel(
          filePath: 'icarus.exe',
          calculatedHash: await _hashBytes(utf8.encode('expected payload')),
          length: fileBytes.length,
        ),
      ],
      appName: 'Icarus',
    );

    final controller = WindowsDesktopUpdateController(
      appArchiveUrl: Uri.parse('https://example.com/app-archive.json'),
      updater: _FakeDesktopUpdater(
        executablePath: '$executablePath\u0000',
        update: update,
      ),
      autoCheck: false,
    );
    addTearDown(controller.dispose);

    await controller.checkVersion();

    await expectLater(
      controller.downloadUpdate(),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.message,
          'message',
          contains('hash mismatch'),
        ),
      ),
    );

    expect(
      await Directory('${installDirectory.path}${Platform.pathSeparator}update')
          .exists(),
      isFalse,
    );
    expect(controller.isDownloaded, isFalse);
    expect(controller.downloadProgress, 0);
  });
}

class _FakeDesktopUpdater extends DesktopUpdater {
  _FakeDesktopUpdater({
    required this.executablePath,
    required this.update,
  });

  final String executablePath;
  final ItemModel update;

  @override
  Future<String?> getExecutablePath() async => executablePath;

  @override
  Future<ItemModel?> versionCheck({
    required String appArchiveUrl,
  }) async {
    return update;
  }
}

Future<String> _hashBytes(List<int> bytes) async {
  final hash = await Blake2b().hash(bytes);
  return base64Encode(hash.bytes);
}
