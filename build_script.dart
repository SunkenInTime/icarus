// ignore_for_file: avoid_print

import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    print('Usage: dart build_script.dart <version> <build_number>');
    print('Example: dart build_script.dart 1.7.2 12');
    exit(1);
  }

  final version = args[0];
  final buildNumber = int.parse(args[1]);
  final fullVersion = '$version+$buildNumber';
  final msixVersion = '$version.0';

  // Update pubspec.yaml
  updatePubspec(fullVersion, msixVersion);

  // Update settings.dart
  updateSettings(buildNumber);

  print('Version updated to $fullVersion');
}

void updatePubspec(String fullVersion, String msixVersion) {
  final file = File('pubspec.yaml');
  String content = file.readAsStringSync();

  // Update main version - fixed regex pattern
  content = content.replaceFirst(
      RegExp(r'version: [\d\.]+\+\d+ #version number'),
      'version: $fullVersion #version number');

  // Update msix version - fixed regex pattern
  content = content.replaceFirst(
      RegExp(r'msix_version: [\d\.]+ #verion number'),
      'msix_version: $msixVersion #verion number');

  file.writeAsStringSync(content);
}

void updateSettings(int buildNumber) {
  final file = File('lib/const/settings.dart');
  String content = file.readAsStringSync();

  content = content.replaceFirst(
      RegExp(r'versionNumber = \d+ //version number here \+1 for each release'),
      'versionNumber = $buildNumber //version number here +1 for each release');

  file.writeAsStringSync(content);
}
