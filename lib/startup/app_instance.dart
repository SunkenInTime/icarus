import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

sealed class AppInstance {
  const AppInstance();

  Future<Directory> supportDirectory();
}

final class InstalledApp extends AppInstance {
  const InstalledApp();

  @override
  Future<Directory> supportDirectory() => getApplicationSupportDirectory();
}

final class SeparateInstance extends AppInstance {
  const SeparateInstance(this.folder);

  final String folder;

  @override
  Future<Directory> supportDirectory() async => Directory(folder);

  File get sessionFile => File('$folder${Platform.pathSeparator}session.json');

  File get authFlowFile =>
      File('$folder${Platform.pathSeparator}auth_flow.json');
}

AppInstance _appInstance = const InstalledApp();

AppInstance get appInstance => _appInstance;

void decideAppInstance(AppInstance instance) => _appInstance = instance;

AppInstance appInstanceAt(String? separateFolder) => switch (separateFolder) {
      null => const InstalledApp(),
      final folder => SeparateInstance(folder),
    };

Future<String> debugLogPath() async =>
    path.join((await appInstance.supportDirectory()).path, 'icarus_debug.log');

Future<String> webViewDataFolder() async =>
    path.join((await appInstance.supportDirectory()).path, 'webview');

Future<Directory> sightlineReportsFolder() async => Directory(
      path.join(
          (await appInstance.supportDirectory()).path, 'sightline-reports'),
    );

LocalStorage? sessionStorageOf(AppInstance instance) => switch (instance) {
      InstalledApp() => null,
      final SeparateInstance separate =>
        FileSessionStorage(separate.sessionFile),
    };

GotrueAsyncStorage? authFlowStorageOf(AppInstance instance) =>
    switch (instance) {
      InstalledApp() => null,
      final SeparateInstance separate =>
        FileAuthFlowStorage(separate.authFlowFile),
    };

Future<String?> storedAuthFlowValue(String key) async =>
    switch (authFlowStorageOf(appInstance)) {
      null => (await SharedPreferences.getInstance()).getString(key),
      final storage => storage.getItem(key: key),
    };

final class FileSessionStorage extends LocalStorage {
  const FileSessionStorage(this._file);

  final File _file;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => _file.existsSync();

  @override
  Future<String?> accessToken() async =>
      _file.existsSync() ? _file.readAsString() : null;

  @override
  Future<void> removePersistedSession() async {
    if (_file.existsSync()) await _file.delete();
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(persistSessionString);
  }
}

final class FileAuthFlowStorage extends GotrueAsyncStorage {
  const FileAuthFlowStorage(this._file);

  final File _file;

  Map<String, String> _read() => _file.existsSync()
      ? (jsonDecode(_file.readAsStringSync()) as Map).cast<String, String>()
      : {};

  Future<void> _write(Map<String, String> items) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(items));
  }

  @override
  Future<String?> getItem({required String key}) async => _read()[key];

  @override
  Future<void> setItem({required String key, required String value}) =>
      _write({..._read(), key: value});

  @override
  Future<void> removeItem({required String key}) =>
      _write(_read()..remove(key));
}
