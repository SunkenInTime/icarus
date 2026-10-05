import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repositoryRoot = Directory.current;

  test('generated Convex API stays inside the collaboration boundary', () {
    final violations = <String>[];
    for (final file in _dartFiles(repositoryRoot, 'lib')) {
      final relativePath = _relativePath(repositoryRoot, file);
      if (relativePath.startsWith('lib/collab/')) continue;
      final source = file.readAsStringSync();
      if (source.contains('collab/generated/') ||
          source.contains('IcarusConvexApi') ||
          source.contains('ConvexOptional<')) {
        violations.add(relativePath);
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Generated client imports and types may only appear in lib/collab.',
    );
  });

  test('collaboration data layer does not import Flutter UI libraries', () {
    final violations = <String>[];
    for (final file in _dartFiles(repositoryRoot, 'lib/collab')) {
      final source = file.readAsStringSync();
      if (source.contains("package:flutter/material.dart") ||
          source.contains("package:flutter/widgets.dart")) {
        violations.add(_relativePath(repositoryRoot, file));
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'The collaboration data layer must not import Flutter UI.',
    );
  });

  test('public route strings stay in generated or transport code', () {
    final spec = jsonDecode(
      File('${repositoryRoot.path}/convex/function_spec.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final routes = (spec['functions'] as List)
        .whereType<Map>()
        .where((entry) => (entry['visibility'] as Map?)?['kind'] == 'public')
        .map((entry) => entry['identifier'] as String)
        .map((identifier) => identifier.replaceFirst('.js:', ':'))
        .toSet();
    final violations = <String>[];

    for (final file in _dartFiles(repositoryRoot, 'lib')) {
      final relativePath = _relativePath(repositoryRoot, file);
      if (relativePath.startsWith('lib/collab/generated/') ||
          relativePath.startsWith('lib/collab/transport/') ||
          relativePath.startsWith('lib/collab/src/')) {
        continue;
      }
      final source = file.readAsStringSync();
      for (final route in routes) {
        final quotedRoute = RegExp("['\"]${RegExp.escape(route)}['\"]");
        if (quotedRoute.hasMatch(source)) {
          violations.add('$relativePath: $route');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Call generated modules instead of spelling Convex routes.',
    );
  });

  test('legacy JSON repository boundary stays deleted', () {
    final collabSource = _dartFiles(repositoryRoot, 'lib/collab')
        .map((file) => file.readAsStringSync())
        .join('\n');
    for (final legacySymbol in const [
      '_decodeJsonPayload',
      '_decodeObjectList',
      'watchFoldersForParent',
      'class CloudFolderSummary',
      'class CloudStrategySummary',
      'factory CloudFolderSummary.fromJson',
      'factory CloudStrategySummary.fromJson',
      'factory CloudImageUploadIntent.fromJson',
      'factory RemoteStrategyHeader.fromJson',
      'factory RemotePage.fromJson',
      'factory RemotePageContent.fromJson',
      'factory RemoteElement.fromJson',
      'factory RemoteLineup.fromJson',
      'factory RemoteImageAsset.fromJson',
    ]) {
      expect(collabSource, isNot(contains(legacySymbol)), reason: legacySymbol);
    }
  });

  test('raw Convex client calls stay inside platform adapters', () {
    final violations = <String>[];
    final directCall = RegExp(
      r'\b(?:ConvexClient\.instance|_client|client)\s*\.\s*'
      r'(?:query|mutation|action|subscribe)\s*\(',
    );
    for (final file in _dartFiles(repositoryRoot, 'lib')) {
      final relativePath = _relativePath(repositoryRoot, file);
      if (relativePath.startsWith('lib/collab/src/')) continue;
      if (directCall.hasMatch(file.readAsStringSync())) {
        violations.add(relativePath);
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Raw calls belong only in the native and web adapters.',
    );
  });
}

Iterable<File> _dartFiles(Directory root, String relativeDirectory) {
  return Directory('${root.path}/$relativeDirectory')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));
}

String _relativePath(Directory root, File file) {
  return file.path.substring(root.path.length + 1).replaceAll('\\', '/');
}
