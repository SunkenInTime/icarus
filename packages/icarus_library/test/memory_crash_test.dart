import 'package:test/test.dart';

import 'crash_harness.dart';

void main() {
  group(MemoryCrashHarness().name, () {
    engineCrashContract(MemoryCrashHarness.new);
    storeCrashContract(MemoryCrashHarness.new);
  });
}
