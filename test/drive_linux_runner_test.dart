import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/drive/linux.dart';

Set<String> _names(String text, RegExp pattern) =>
    {for (final match in pattern.allMatches(text)) match.group(1)!};

void main() {
  final driver = [
    File('lib/dev/drive/drive.dart').readAsStringSync(),
    File('lib/dev/drive/drive_session.dart').readAsStringSync(),
  ].join('\n');
  final read = _names(driver, RegExp(r"\['(ICARUS_DRIVE_\w+)'\]"));
  final setOnWindows = _names(
    File('tool/drive/run.ps1').readAsStringSync(),
    RegExp(r'\$env:(ICARUS_DRIVE_\w+)\s*='),
  );
  final setOnLinux = _names(
    File('tool/drive/linux.dart').readAsStringSync(),
    RegExp(r"'(ICARUS_DRIVE_\w+)':"),
  );

  test('both runners set every variable the driver reads', () {
    expect(read, contains('ICARUS_DRIVE_SCRIPT'));
    expect(setOnWindows, containsAll(read));
    expect(setOnLinux, containsAll(read.difference(windowsOnlyEnvironment)));
  });

  test('the steps Linux refuses are steps the driver has', () {
    for (final step in linuxRefusedSteps.keys) {
      expect(driver, contains("case '$step':"));
    }
  });

  test('a script with a Windows-only step is refused by name', () {
    expect(
      refusalsFor('paste.json', [
        {'wait': 1},
        {'clipboard': 'a.bmp'},
        {'clipboard': 'b.bmp'},
      ]),
      hasLength(1),
    );
    expect(
        refusalsFor('fine.json', [
          {'wait': 1},
        ]),
        isEmpty);
  });

  test('both builds refuse the production deployment', () {
    expect(
      File('tool/drive/build.ps1').readAsStringSync(),
      contains(productionDeployment),
    );
    expect(
      () => convexDefines('https://$productionDeployment.convex.cloud'),
      throwsA(isA<UsageError>()),
    );
    expect(convexDefines('https://some-preview-12.convex.cloud'), [
      '--dart-define=ICARUS_CONVEX_DEPLOYMENT_URL=https://some-preview-12.convex.cloud',
      '--dart-define=ICARUS_CONVEX_CLIENT_ID=dev:some-preview-12',
    ]);
    expect(() => convexDefines('http://x.convex.cloud'),
        throwsA(isA<UsageError>()));
  });

  test('a password is read from its own row only', () {
    const table = '| email | password | sign-in |\n'
        '| --- | --- | --- |\n'
        '| a@test.example | first | email |\n'
        '| aa@test.example | second | email |\n';
    expect(passwordFor('a@test.example', table), 'first');
    expect(passwordFor('aa@test.example', table), 'second');
    expect(passwordFor('b@test.example', table), isNull);
  });
}
