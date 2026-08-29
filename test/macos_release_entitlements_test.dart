import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release sandbox permits cloud access and user-selected exports', () {
    final entitlements =
        File('macos/Runner/Release.entitlements').readAsStringSync();
    bool isEnabled(String key) => RegExp(
          '<key>${RegExp.escape(key)}</key>\\s*<true\\s*/>',
        ).hasMatch(entitlements);

    expect(isEnabled('com.apple.security.network.client'), isTrue);
    expect(
      isEnabled('com.apple.security.files.user-selected.read-write'),
      isTrue,
    );
  });
}
