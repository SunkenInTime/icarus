import 'dart:convert';
import 'dart:io';

import 'verify_tactical_alignment_navigation_test.dart' as navigation;

void main() {
  const path = String.fromEnvironment('NAVIGATION_INVENTORY');
  final inventory = jsonDecode(File(path).readAsStringSync()) as Map;
  for (final row in inventory['maps'] as List) {
    navigation.verifyNavigationCandidate(
        candidatePath: row['navigation'] as String,
        candidateMap: row['map'] as String);
  }
}
