import 'dart:io';

import 'package:icarus_convex_client_gauntlet/contract_gate.dart';

Future<void> main(List<String> args) async {
  final outputIndex = args.indexOf('--output');
  final outputPath = outputIndex == -1 || outputIndex + 1 >= args.length
      ? null
      : args[outputIndex + 1];
  final result = await evaluateContractGate();
  final json = '${result.toPrettyJson()}\n';
  stdout.write(json);
  if (outputPath != null) {
    File(outputPath).writeAsStringSync(json);
  }
}
