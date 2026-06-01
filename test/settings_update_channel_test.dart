import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';

void main() {
  test('buildDesktopUpdaterArchiveUrl returns stable archive URL', () {
    final uri = buildDesktopUpdaterArchiveUrl('stable');

    expect(
      uri.toString(),
      'https://sunkenintime.github.io/icarus/updates/windows/stable/app-archive.json',
    );
  });

  test('buildDesktopUpdaterArchiveUrl returns prerelease archive URL', () {
    final uri = buildDesktopUpdaterArchiveUrl('prerelease');

    expect(
      uri.toString(),
      'https://sunkenintime.github.io/icarus/updates/windows/prerelease/app-archive.json',
    );
  });

  test('buildDesktopUpdaterArchiveUrl normalizes pre-release alias', () {
    final uri = buildDesktopUpdaterArchiveUrl('pre-release');

    expect(
      uri.toString(),
      'https://sunkenintime.github.io/icarus/updates/windows/prerelease/app-archive.json',
    );
  });

  test('normalizeUpdateChannel resolves prerelease aliases', () {
    expect(normalizeUpdateChannel('prerelease'), 'prerelease');
    expect(normalizeUpdateChannel('pre-release'), 'prerelease');
    expect(normalizeUpdateChannel('pre_release'), 'prerelease');
  });

  test('updateChannelLabel returns stable and prerelease labels', () {
    expect(updateChannelLabel('stable'), 'Stable');
    expect(updateChannelLabel('pre-release'), 'Pre-release');
  });

  test('default update channel remains stable', () {
    expect(kUpdateChannel, 'stable');
    expect(kResolvedUpdateChannel, 'stable');
    expect(
      Settings.desktopUpdaterArchiveUrl,
      buildDesktopUpdaterArchiveUrl('stable'),
    );
  });
}
