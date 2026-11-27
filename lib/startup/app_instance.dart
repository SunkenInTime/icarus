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

String debugLogPathIn(Directory support) =>
    path.join(support.path, 'icarus_debug.log');

String webViewDataFolderIn(Directory support) =>
    path.join(support.path, 'webview');

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

final class _SerialFile {
  _SerialFile._(this._file);

  factory _SerialFile(File file) =>
      _byPath.putIfAbsent(file.path, () => _SerialFile._(file));

  static final _byPath = <String, _SerialFile>{};

  final File _file;
  Future<void> _last = Future.value();

  Future<T> run<T>(Future<T> Function() work) {
    final done = _last.then((_) => work());
    _last = done.then((_) {}, onError: (Object _) {});
    return done;
  }

  Future<String?> readNow() async =>
      _file.existsSync() ? _file.readAsString() : null;

  Future<void> writeNow(String text) async {
    await _file.parent.create(recursive: true);
    final beside = File('${_file.path}.writing');
    await beside.writeAsString(text, flush: true);
    await beside.rename(_file.path);
  }

  Future<void> deleteNow() async {
    if (_file.existsSync()) await _file.delete();
  }
}

final class FileSessionStorage extends LocalStorage {
  FileSessionStorage(File file) : _file = _SerialFile(file);

  final _SerialFile _file;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() =>
      _file.run(() async => await _file.readNow() != null);

  @override
  Future<String?> accessToken() => _file.run(_file.readNow);

  @override
  Future<void> removePersistedSession() => _file.run(_file.deleteNow);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _file.run(() => _file.writeNow(persistSessionString));
}

final class FileAuthFlowStorage extends GotrueAsyncStorage {
  FileAuthFlowStorage(File file) : _file = _SerialFile(file);

  final _SerialFile _file;

  Future<Map<String, String>> _items() async {
    final text = await _file.readNow();
    if (text == null) return {};
    final Object? stored;
    try {
      stored = jsonDecode(text);
    } on FormatException {
      return {};
    }
    if (stored is! Map) return {};
    return {
      for (final MapEntry(:key, :value) in stored.entries)
        if (key is String && value is String) key: value,
    };
  }

  @override
  Future<String?> getItem({required String key}) =>
      _file.run(() async => (await _items())[key]);

  @override
  Future<void> setItem({required String key, required String value}) =>
      _file.run(() async =>
          _file.writeNow(jsonEncode({...await _items(), key: value})));

  @override
  Future<void> removeItem({required String key}) =>
      _file.run(() async => _file.writeNow(jsonEncode(await _items()
        ..remove(key))));
}
