@TestOn('vm')
library;

import 'package:icarus_library/engine_contract.dart';
import 'package:test/test.dart';

import '../crash_harness.dart';
import 'fault_disk.dart';
import 'fault_harness.dart';

void main() {
  for (final loss in const [
    KeepsUnsynced(),
    DropsUnsynced(),
    TearsUnsynced(1),
    TearsUnsynced(2),
  ]) {
    group(SqliteCrashHarness(loss).name, () {
      group('the engine contract', () {
        for (final check in engineContract) {
          test(check.name, () async {
            final harness = FaultContractHarness(loss);
            final result = await check.run(harness);
            harness.drive.unregister();
            expect(result, isA<Passed>(), reason: '$result');
          });
        }
      });
      engineCrashContract(() => SqliteCrashHarness(loss));
      storeCrashContract(() => SqliteCrashHarness(loss));
    });
  }
}
