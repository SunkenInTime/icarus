import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/release_notes.dart';
import 'package:icarus/const/settings.dart';

void main() {
  group('ReleaseNotes.parse', () {
    test('sorts newest first and keeps the highest build of a version', () {
      final entries = ReleaseNotes.parse({
        'items': [
          {
            'version': '4.6.1+99',
            'shortVersion': 99,
            'date': '2026-09-01',
            'changes': [
              {'message': 'Old thing', 'type': 'fix'},
            ],
          },
          {
            'version': '4.6.2+101',
            'shortVersion': 101,
            'changes': [
              {'message': 'First cut'},
            ],
          },
          {
            'version': '4.6.2+102',
            'shortVersion': 102,
            'date': '2026-09-20',
            'changes': [
              {'message': 'Signed installers', 'type': 'feature'},
              {'message': '   ', 'type': 'noise'},
              'not a map',
            ],
          },
        ],
      });

      expect(entries.map((e) => e.version), ['4.6.2+102', '4.6.1+99']);
      expect(entries.first.versionName, '4.6.2');
      expect(entries.first.date, '2026-09-20');
      expect(entries.first.changes.map((c) => c.message), [
        'Signed installers',
      ]);
      expect(entries.first.changes.single.type, 'feature');
      expect(entries.last.date, '2026-09-01');
    });

    test('derives the build from the version when shortVersion is missing',
        () {
      final entries = ReleaseNotes.parse({
        'items': [
          {'version': '4.5.0+90', 'changes': []},
          {'version': '', 'shortVersion': 1},
          {'version': 'broken', 'changes': []},
        ],
      });

      expect(entries.length, 1);
      expect(entries.single.shortVersion, 90);
      expect(entries.single.changes, isEmpty);
    });

    test('returns nothing for a manifest without items', () {
      expect(ReleaseNotes.parse({}), isEmpty);
      expect(ReleaseNotes.parse({'items': 'nope'}), isEmpty);
    });

    test('marks the installed and newer builds', () {
      final installed = ReleaseNotesEntry(
        version: '${Settings.versionName}+${Settings.versionNumber}',
        shortVersion: Settings.versionNumber,
        changes: const [],
      );
      final newer = ReleaseNotesEntry(
        version: 'x+${Settings.versionNumber + 1}',
        shortVersion: Settings.versionNumber + 1,
        changes: const [],
      );

      expect(installed.isInstalled, isTrue);
      expect(installed.isNewerThanInstalled, isFalse);
      expect(newer.isInstalled, isFalse);
      expect(newer.isNewerThanInstalled, isTrue);
    });
  });

  group('ReleaseNotes.fetch', () {
    tearDown(() => ReleaseNotes.fetchManifestOverride = null);

    test('throws when the manifest cannot be fetched', () async {
      ReleaseNotes.fetchManifestOverride = () async => null;
      expect(ReleaseNotes.fetch(), throwsA(isA<ReleaseNotesUnavailable>()));
    });

    test('parses the fetched manifest', () async {
      ReleaseNotes.fetchManifestOverride = () async => {
            'items': [
              {'version': '1.0.0+1', 'shortVersion': 1, 'changes': []},
            ],
          };
      final entries = await ReleaseNotes.fetch();
      expect(entries.single.version, '1.0.0+1');
    });
  });
}
