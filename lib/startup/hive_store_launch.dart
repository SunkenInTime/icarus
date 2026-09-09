import 'dart:convert';
import 'dart:io';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:path/path.dart' as path;

final class HiveStoreLaunchException implements Exception {
  const HiveStoreLaunchException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

final class HiveStoreLaunch {
  const HiveStoreLaunch._({
    required this.fileOpenArgs,
    required String? alternateHiveDirectory,
  }) : _alternateHiveDirectory = alternateHiveDirectory;

  static const optionName = '--hive-store-dir';
  static const defaultWindowsSingleInstanceId = 'icarus_single_instance';

  final List<String> fileOpenArgs;
  final String? _alternateHiveDirectory;

  static HiveStoreLaunch parse(List<String> rawArgs) {
    final fileOpenArgs = <String>[];
    String? alternateHiveDirectory;
    var sawOption = false;

    for (var index = 0; index < rawArgs.length; index += 1) {
      final argument = rawArgs[index];
      if (argument == optionName) {
        if (sawOption) {
          throw const HiveStoreLaunchException(
            '$optionName may only be supplied once.',
          );
        }
        if (index + 1 >= rawArgs.length ||
            rawArgs[index + 1] == optionName ||
            rawArgs[index + 1].startsWith('$optionName=')) {
          throw const HiveStoreLaunchException(
            '$optionName requires an absolute directory path.',
          );
        }
        sawOption = true;
        alternateHiveDirectory = rawArgs[++index];
        _validateOptionValue(alternateHiveDirectory);
        continue;
      }

      if (argument.startsWith('$optionName=')) {
        if (sawOption) {
          throw const HiveStoreLaunchException(
            '$optionName may only be supplied once.',
          );
        }
        sawOption = true;
        alternateHiveDirectory = argument.substring(optionName.length + 1);
        _validateOptionValue(alternateHiveDirectory);
        continue;
      }

      fileOpenArgs.add(argument);
    }

    return HiveStoreLaunch._(
      fileOpenArgs: List.unmodifiable(fileOpenArgs),
      alternateHiveDirectory: alternateHiveDirectory,
    );
  }

  void validateForWeb() {
    if (_alternateHiveDirectory == null) return;
    throw const HiveStoreLaunchException(
      '$optionName is only available in desktop builds.',
    );
  }

  Future<PreparedHiveStore?> prepareAlternateStore({
    required Future<Directory> Function() getDefaultHiveDirectory,
    Future<void> Function(Directory directory)? probeDirectory,
  }) async {
    final requestedPath = _alternateHiveDirectory;
    if (requestedPath == null) return null;
    if (!path.isAbsolute(requestedPath)) {
      throw HiveStoreLaunchException(
        '$optionName requires an absolute path: $requestedPath',
      );
    }

    try {
      final requestedDirectory = Directory(path.normalize(requestedPath));
      await requestedDirectory.create(recursive: true);
      final canonicalPath = path.normalize(
        await requestedDirectory.resolveSymbolicLinks(),
      );
      final canonicalDirectory = Directory(canonicalPath);
      await (probeDirectory ?? _probeDirectory)(canonicalDirectory);

      final defaultDirectory = await getDefaultHiveDirectory();
      final defaultPath = await _resolvedDirectoryPath(defaultDirectory);
      final isDefaultDirectory =
          _pathIdentity(canonicalPath) == _pathIdentity(defaultPath);

      return PreparedHiveStore(
        hiveDirectoryPath: canonicalPath,
        windowsSingleInstanceId: isDefaultDirectory
            ? defaultWindowsSingleInstanceId
            : await _windowsSingleInstanceId(canonicalPath),
      );
    } on HiveStoreLaunchException {
      rethrow;
    } catch (error) {
      throw HiveStoreLaunchException(
        'Could not prepare Hive store directory: $requestedPath',
        error,
      );
    }
  }

  static void _validateOptionValue(String value) {
    if (value.isEmpty) {
      throw const HiveStoreLaunchException(
        '$optionName requires a non-empty directory path.',
      );
    }
    if (value.contains('\u0000')) {
      throw const HiveStoreLaunchException(
        '$optionName cannot contain a NUL character.',
      );
    }
  }

  static Future<void> _probeDirectory(Directory directory) async {
    final probeDirectory = await directory.createTemp('.icarus-hive-probe-');
    try {
      final probeFile = File(path.join(probeDirectory.path, 'write-probe'));
      await probeFile.writeAsBytes(const [0], flush: true);
    } finally {
      if (await probeDirectory.exists()) {
        await probeDirectory.delete(recursive: true);
      }
    }
  }

  static Future<String> _resolvedDirectoryPath(Directory directory) async {
    final absoluteDirectory =
        Directory(path.normalize(directory.absolute.path));
    if (!await absoluteDirectory.exists()) return absoluteDirectory.path;
    return path.normalize(await absoluteDirectory.resolveSymbolicLinks());
  }

  static String _pathIdentity(String directoryPath) {
    final normalized = path.normalize(directoryPath);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static Future<String> _windowsSingleInstanceId(
    String canonicalPath,
  ) async {
    final digest =
        await Sha256().hash(utf8.encode(_pathIdentity(canonicalPath)));
    final hex = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${defaultWindowsSingleInstanceId}_$hex';
  }
}

final class PreparedHiveStore {
  const PreparedHiveStore({
    required this.hiveDirectoryPath,
    required this.windowsSingleInstanceId,
  });

  final String hiveDirectoryPath;
  final String windowsSingleInstanceId;
}
