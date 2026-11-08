import 'dart:convert';
import 'dart:io';

import 'package:icarus_convex_client_gauntlet/full_spec_gate.dart';

/// Generates Dartvex bindings for every public function in Icarus's committed
/// function spec and reports which results come out fully typed.
///
///     dart run bin/full_spec.dart [--analyze] [--output results/full_spec_gate.json]
///
/// `--analyze` also runs `dart analyze` over the bindings for every function
/// Dartvex accepted. It takes minutes, because those bindings are tens of
/// megabytes. Generated files land in `lib/_full_spec_generated` so analysis
/// resolves the `dartvex` import, and are deleted afterwards.
Future<void> main(List<String> args) async {
  final outputIndex = args.indexOf('--output');
  final outputPath = outputIndex == -1 || outputIndex + 1 >= args.length
      ? null
      : args[outputIndex + 1];
  final root = Directory.current.absolute;
  final report = await evaluateFullSpecGate(
    specFile: File('${root.path}/../../convex/function_spec.json'),
    scratch: Directory('${root.path}/lib/_full_spec_generated'),
    analyze: args.contains('--analyze'),
  );
  final json = '${const JsonEncoder.withIndent('  ').convert(report)}\n';
  stdout.write(json);
  if (outputPath != null) {
    File(outputPath).writeAsStringSync(json);
  }
}
