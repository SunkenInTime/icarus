import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Centralized storage layout for the Hackathon edition.
///
/// Everything persisted to disk should live under a single, edition-scoped
/// directory so it never collides with a normal Icarus install.
class AppStorage {
  // Keep this stable; changing it creates a new "profile".
  static const String _editionRootName = 'icarus_hackathon';

  static const String _hiveDirName = 'hive';
  static const String _strategiesDirName = 'strategies';
  static const String _imagesDirName = 'images';
  static const String _webViewDirName = 'webview';

  // Temp namespace used while importing/exporting.
  static const String _tempNamespace = 'xyz.icarus-hackathon';

  static Future<Directory> _ensureDir(String p) async {
    final d = Directory(p);
    if (await d.exists()) return d;
    return d.create(recursive: true);
  }

  static Future<String> supportRootPath() async {
    final base = await getApplicationSupportDirectory();
    return path.join(base.path, _editionRootName);
  }

  static Future<Directory> supportRoot() async {
    return _ensureDir(await supportRootPath());
  }

  static Future<String> hiveRootPath() async {
    return path.join(await supportRootPath(), _hiveDirName);
  }

  static Future<Directory> hiveRoot() async {
    return _ensureDir(await hiveRootPath());
  }

  static Future<String> strategiesRootPath() async {
    return path.join(await supportRootPath(), _strategiesDirName);
  }

  static Future<Directory> strategiesRoot() async {
    return _ensureDir(await strategiesRootPath());
  }

  static Future<String> strategyRootPath(String strategyId) async {
    return path.join(await strategiesRootPath(), strategyId);
  }

  static Future<Directory> strategyRoot(String strategyId) async {
    return _ensureDir(await strategyRootPath(strategyId));
  }

  static Future<String> imagesRootPath(String strategyId) async {
    return path.join(await strategyRootPath(strategyId), _imagesDirName);
  }

  static Future<Directory> imagesRoot(String strategyId) async {
    return _ensureDir(await imagesRootPath(strategyId));
  }

  static Future<String> webViewRootPath() async {
    return path.join(await supportRootPath(), _webViewDirName);
  }

  static Future<Directory> webViewRoot() async {
    return _ensureDir(await webViewRootPath());
  }

  static Future<Directory> tempStrategyRoot(String strategyId) async {
    final temp = await getTemporaryDirectory();
    return _ensureDir(path.join(temp.path, _tempNamespace, strategyId));
  }
}
