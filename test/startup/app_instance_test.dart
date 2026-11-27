import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:icarus/services/auth_callback_uri.dart';
import 'package:icarus/startup/app_instance.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late Directory scratch;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('icarus-support-');
    scratch = await Directory.systemTemp.createTemp('icarus-scratch-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => support.path);
  });

  tearDown(() async {
    decideAppInstance(const InstalledApp());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await support.delete(recursive: true);
    await scratch.delete(recursive: true);
  });

  test(
      'before an instance is decided the app is the installed one, so a '
      'launch refused over its store folder logs to the support folder',
      () async {
    expect(appInstance, isA<InstalledApp>());
    expect(
      debugLogPathIn(await appInstance.supportDirectory()),
      path.join(support.path, 'icarus_debug.log'),
    );
  });

  test(
      'no store folder is the installed app; a store folder is a separate '
      'instance at that folder', () {
    expect(appInstanceAt(null), isA<InstalledApp>());
    expect(
      appInstanceAt(scratch.path),
      isA<SeparateInstance>()
          .having((instance) => instance.folder, 'folder', scratch.path),
    );
  });

  group('the installed app names today\'s places', () {
    setUp(() => decideAppInstance(const InstalledApp()));

    test(
        'the support folder, the debug log, the webview profile and '
        'sightline reports', () async {
      expect((await appInstance.supportDirectory()).path, support.path);
      expect(
        debugLogPathIn(await appInstance.supportDirectory()),
        path.join(support.path, 'icarus_debug.log'),
      );
      expect(
        webViewDataFolderIn(await appInstance.supportDirectory()),
        path.join(support.path, 'webview'),
      );
      expect(
        (await sightlineReportsFolder()).path,
        path.join(support.path, 'sightline-reports'),
      );
      expect(
        (await ReplayFiles().icarusReplaysDirectory()).path,
        path.join(support.path, 'replays'),
      );
    });

    test(
        'the sign-in session and the sign-in flow keep the default storage, '
        'and the password reset check reads shared preferences', () async {
      expect(sessionStorageOf(appInstance), isNull);
      expect(authFlowStorageOf(appInstance), isNull);
      SharedPreferences.setMockInitialValues({
        pkceVerifierStorageKey: 'kept-by-the-installed-app',
      });
      expect(
        await storedAuthFlowValue(pkceVerifierStorageKey),
        'kept-by-the-installed-app',
      );
    });
  });

  group('a separate instance keeps everything in its folder', () {
    setUp(() => decideAppInstance(SeparateInstance(scratch.path)));

    test(
        'the support folder, the debug log, the webview profile, sightline '
        'reports and replays', () async {
      expect((await appInstance.supportDirectory()).path, scratch.path);
      expect(
        debugLogPathIn(await appInstance.supportDirectory()),
        path.join(scratch.path, 'icarus_debug.log'),
      );
      expect(
        webViewDataFolderIn(await appInstance.supportDirectory()),
        path.join(scratch.path, 'webview'),
      );
      expect(
        (await sightlineReportsFolder()).path,
        path.join(scratch.path, 'sightline-reports'),
      );
      expect(
        (await ReplayFiles().icarusReplaysDirectory()).path,
        path.join(scratch.path, 'replays'),
      );
      expect(await support.list().isEmpty, isTrue);
    });

    test('its sign-in session is a file in its folder', () async {
      final storage = sessionStorageOf(appInstance)!;

      await storage.persistSession('{"session":"separate"}');

      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), '{"session":"separate"}');
      expect(
        File(path.join(scratch.path, 'session.json')).existsSync(),
        isTrue,
      );
      await storage.removePersistedSession();
      expect(await storage.hasAccessToken(), isFalse);
      expect(await support.list().isEmpty, isTrue);
    });

    test(
        'its sign-in flow is a file in its folder, and the password reset '
        'check reads it, not shared preferences', () async {
      SharedPreferences.setMockInitialValues({
        pkceVerifierStorageKey: 'kept-by-the-installed-app',
      });
      final storage = authFlowStorageOf(appInstance)!;

      await storage.setItem(key: pkceVerifierStorageKey, value: 'separate');

      expect(await storedAuthFlowValue(pkceVerifierStorageKey), 'separate');
      expect(
        File(path.join(scratch.path, 'auth_flow.json')).existsSync(),
        isTrue,
      );
      await storage.removeItem(key: pkceVerifierStorageKey);
      expect(await storedAuthFlowValue(pkceVerifierStorageKey), isNull);
      expect(await support.list().isEmpty, isTrue);
    });

    test(
        'a session write left running is ordered before a later sign-out, '
        'so no stale session is left', () async {
      final storage = sessionStorageOf(appInstance)!;

      final writing = storage.persistSession('{"session":"stale"}');
      await storage.removePersistedSession();
      await writing;

      expect(await storage.hasAccessToken(), isFalse);
      expect(
        File(path.join(scratch.path, 'session.json')).existsSync(),
        isFalse,
      );
    });

    test(
        'a sign-in flow file that is not JSON reads as empty and still '
        'takes the next sign-in', () async {
      File(path.join(scratch.path, 'auth_flow.json'))
          .writeAsStringSync('{not json');
      final storage = authFlowStorageOf(appInstance)!;

      expect(await storage.getItem(key: pkceVerifierStorageKey), isNull);
      await storage.setItem(key: pkceVerifierStorageKey, value: 'next');
      expect(await storage.getItem(key: pkceVerifierStorageKey), 'next');
    });

    test(
        'a sign-in flow file holding a value that is not text keeps its text '
        'values and still takes the next sign-in', () async {
      final file = File(path.join(scratch.path, 'auth_flow.json'))
        ..writeAsStringSync('{"other": 1, "kept": "as it was"}');
      final storage = authFlowStorageOf(appInstance)!;

      expect(await storage.getItem(key: 'kept'), 'as it was');
      expect(await storage.getItem(key: 'other'), isNull);
      await storage.setItem(key: pkceVerifierStorageKey, value: 'next');
      expect(await storage.getItem(key: pkceVerifierStorageKey), 'next');
      expect(jsonDecode(file.readAsStringSync()), {
        'kept': 'as it was',
        pkceVerifierStorageKey: 'next',
      });
    });

    test(
        'a sign-in flow file that is JSON but not an object reads as empty',
        () async {
      File(path.join(scratch.path, 'auth_flow.json')).writeAsStringSync('[1]');
      final storage = authFlowStorageOf(appInstance)!;

      expect(await storage.getItem(key: pkceVerifierStorageKey), isNull);
      await storage.setItem(key: pkceVerifierStorageKey, value: 'next');
      expect(await storage.getItem(key: pkceVerifierStorageKey), 'next');
    });

    test('a write that fails leaves the file it would have replaced', () async {
      final storage = sessionStorageOf(appInstance)!;
      await storage.persistSession('{"session":"kept"}');
      Directory(path.join(scratch.path, 'session.json.writing')).createSync();

      await expectLater(
        storage.persistSession('{"session":"lost"}'),
        throwsA(isA<FileSystemException>()),
      );

      expect(await storage.accessToken(), '{"session":"kept"}');
    });
  });
}
