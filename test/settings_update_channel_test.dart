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

  test('default update channel remains stable', () {
    expect(kUpdateChannel, 'stable');
    expect(
      Settings.desktopUpdaterArchiveUrl,
      buildDesktopUpdaterArchiveUrl('stable'),
    );
  });
}
