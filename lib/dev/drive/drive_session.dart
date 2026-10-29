import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Where a driver build keeps its sign-in: a file of its own
/// (ICARUS_DRIVE_SESSION, which tool/drive/run.ps1 sets per instance).
/// Every other build on the machine, the installed app included, shares one
/// saved session, so a driver run would otherwise sign in as whoever was
/// signed in last, or sign them out.
class DriveSessionStorage extends LocalStorage {
  DriveSessionStorage()
      : _file = File(Platform.environment['ICARUS_DRIVE_SESSION'] ??
            '${Directory.systemTemp.path}${Platform.pathSeparator}'
                'icarus-drive-session.json');

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
  Future<void> persistSession(String persistSessionString) =>
      _file.writeAsString(persistSessionString);
}
