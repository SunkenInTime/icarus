import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';

/// The server refuses a strategy on a map missing from its own list, so a
/// map added here and not there could not be saved to the cloud.
void main() {
  test('the server knows every map this build offers', () {
    final source = File('convex/lib/maps.ts').readAsStringSync();
    final list = RegExp(r'const knownMapNames = new Set\(\[([^\]]*)\]\)')
        .firstMatch(source)!
        .group(1)!;
    final serverNames = {
      for (final match in RegExp(r'"([^"]+)"').allMatches(list)) match.group(1),
    };
    expect(serverNames, containsAll(Maps.mapNames.values));
  });
}
