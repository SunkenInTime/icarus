import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/startup/hive_store_launch.dart';
import 'package:path/path.dart' as path;

void main() {
  group('HiveStoreLaunch.parse', () {
    test('keeps file arguments unchanged when no option is present', () {
      final launch = HiveStoreLaunch.parse(['first.ica', 'second.ica']);

      expect(launch.fileOpenArgs, ['first.ica', 'second.ica']);
    });

    test('consumes the separate option and value', () {
      final launch = HiveStoreLaunch.parse([
        'first.ica',
        HiveStoreLaunch.optionName,
        '/tmp/icarus-demo',
        'second.ica',
      ]);

      expect(launch.fileOpenArgs, ['first.ica', 'second.ica']);
    });

    test('consumes the equals form', () {
      final launch = HiveStoreLaunch.parse([
        '${HiveStoreLaunch.optionName}=/tmp/icarus-demo',
        'strategy.ica',
      ]);

      expect(launch.fileOpenArgs, ['strategy.ica']);
    });

    test('rejects duplicate options', () {
      expect(
        () => HiveStoreLaunch.parse([
          '${HiveStoreLaunch.optionName}=/tmp/one',
          HiveStoreLaunch.optionName,
          '/tmp/two',
        ]),
        throwsA(isA<HiveStoreLaunchException>()),
      );
    });

    test('rejects missing, empty, and NUL values', () {
      for (final arguments in [
        [HiveStoreLaunch.optionName],
        ['${HiveStoreLaunch.optionName}='],
        ['${HiveStoreLaunch.optionName}=/tmp/bad\u0000path'],
      ]) {
        expect(
          () => HiveStoreLaunch.parse(arguments),
          throwsA(isA<HiveStoreLaunchException>()),
        );
      }
    });
  });

  group('HiveStoreLaunch.prepareAlternateStore', () {
    late Directory testRoot;

    setUp(() async {
      testRoot = await Directory.systemTemp.createTemp('icarus-hive-launch-');
    });

    tearDown(() async {
      if (await testRoot.exists()) {
        await testRoot.delete(recursive: true);
      }
    });

    test('does no filesystem work without an alternate option', () async {
      var requestedDefault = false;
      var probedDirectory = false;
      final launch = HiveStoreLaunch.parse(const []);

      final prepared = await launch.prepareAlternateStore(
        getDefaultHiveDirectory: () async {
          requestedDefault = true;
          return testRoot;
        },
        probeDirectory: (_) async {
          probedDirectory = true;
        },
      );

      expect(prepared, isNull);
      expect(requestedDefault, isFalse);
      expect(probedDirectory, isFalse);
    });

    test('rejects a relative path before filesystem work', () async {
      var requestedDefault = false;
      var probedDirectory = false;
      final launch = HiveStoreLaunch.parse([
        HiveStoreLaunch.optionName,
        'relative/demo-hive',
      ]);

      await expectLater(
        launch.prepareAlternateStore(
          getDefaultHiveDirectory: () async {
            requestedDefault = true;
            return testRoot;
          },
          probeDirectory: (_) async {
            probedDirectory = true;
          },
        ),
        throwsA(isA<HiveStoreLaunchException>()),
      );
      expect(requestedDefault, isFalse);
      expect(probedDirectory, isFalse);
    });

    test('creates, resolves, and probes an alternate directory', () async {
      final requestedDirectory = Directory(
        path.join(testRoot.path, 'nested', '..', 'demo-hive'),
      );
      Directory? probedDirectory;
      final launch = HiveStoreLaunch.parse([
        '${HiveStoreLaunch.optionName}=${requestedDirectory.path}',
      ]);

      final prepared = await launch.prepareAlternateStore(
        getDefaultHiveDirectory: () async =>
            Directory(path.join(testRoot.path, 'default-hive')),
        probeDirectory: (directory) async {
          probedDirectory = directory;
        },
      );

      final resolvedRequestedPath = path.normalize(
        await Directory(
          path.normalize(requestedDirectory.path),
        ).resolveSymbolicLinks(),
      );
      expect(prepared, isNotNull);
      expect(prepared!.hiveDirectoryPath, resolvedRequestedPath);
      expect(probedDirectory?.path, resolvedRequestedPath);
      expect(await Directory(resolvedRequestedPath).exists(), isTrue);
      expect(
        prepared.windowsSingleInstanceId,
        matches(RegExp(r'^icarus_single_instance_[0-9a-f]{64}$')),
      );
    });

    test('uses the legacy instance id for the default directory', () async {
      final defaultDirectory = Directory(path.join(testRoot.path, 'default'));
      await defaultDirectory.create();
      final launch = HiveStoreLaunch.parse([
        HiveStoreLaunch.optionName,
        path.join(defaultDirectory.path, '.'),
      ]);

      final prepared = await launch.prepareAlternateStore(
        getDefaultHiveDirectory: () async => defaultDirectory,
        probeDirectory: (_) async {},
      );

      expect(
        prepared?.windowsSingleInstanceId,
        HiveStoreLaunch.defaultWindowsSingleInstanceId,
      );
    });

    test('maps a symlink alias of the default directory to the legacy id',
        () async {
      if (Platform.isWindows) return;

      final defaultDirectory = Directory(path.join(testRoot.path, 'default'));
      await defaultDirectory.create();
      final alias = Link(path.join(testRoot.path, 'default-alias'));
      await alias.create(defaultDirectory.path);
      final launch = HiveStoreLaunch.parse([
        HiveStoreLaunch.optionName,
        alias.path,
      ]);

      final prepared = await launch.prepareAlternateStore(
        getDefaultHiveDirectory: () async => defaultDirectory,
        probeDirectory: (_) async {},
      );

      expect(
        prepared?.windowsSingleInstanceId,
        HiveStoreLaunch.defaultWindowsSingleInstanceId,
      );
    });

    test('wraps an unusable-directory failure without falling back', () async {
      final requestedDirectory = Directory(path.join(testRoot.path, 'blocked'));
      final launch = HiveStoreLaunch.parse([
        HiveStoreLaunch.optionName,
        requestedDirectory.path,
      ]);

      await expectLater(
        launch.prepareAlternateStore(
          getDefaultHiveDirectory: () async => testRoot,
          probeDirectory: (_) async {
            throw const FileSystemException('blocked');
          },
        ),
        throwsA(
          isA<HiveStoreLaunchException>().having(
            (error) => error.cause,
            'cause',
            isA<FileSystemException>(),
          ),
        ),
      );
    });
  });

  group('HiveStoreLaunch.validateForWeb', () {
    test('allows the default IndexedDB store', () {
      expect(HiveStoreLaunch.parse(const []).validateForWeb, returnsNormally);
    });

    test('rejects a filesystem override', () {
      final launch = HiveStoreLaunch.parse([
        '${HiveStoreLaunch.optionName}=/tmp/icarus-demo',
      ]);

      expect(
        launch.validateForWeb,
        throwsA(isA<HiveStoreLaunchException>()),
      );
    });
  });
}
