import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

final class HiveFiles {
  HiveFiles(Map<String, String> digests) : digests = Map.unmodifiable(digests);

  final Map<String, String> digests;

  static Future<HiveFiles> of(Directory directory) async => HiveFiles({
        for (final file in directory.listSync().whereType<File>())
          if (path.extension(file.path) == '.hive')
            path.basename(file.path):
                sha256.convert(await file.readAsBytes()).toString(),
      });

  List<String> changedSince(HiveFiles before) => [
        for (final name in {...before.digests.keys, ...digests.keys})
          if (before.digests[name] != digests[name]) name,
      ]..sort();

  int get count => digests.length;
}
