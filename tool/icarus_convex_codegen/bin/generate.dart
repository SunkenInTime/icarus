import 'dart:io';

import 'package:icarus_convex_codegen/icarus_convex_codegen.dart';
import 'package:path/path.dart' as path;

Future<void> main(List<String> arguments) async {
  try {
    final repositoryRoot = _repositoryRoot(arguments);
    final contract = parseContract(
      functionSpecFile: File(
        path.join(repositoryRoot, 'convex', 'function_spec.json'),
      ),
      errorCodesFile: File(
        path.join(repositoryRoot, 'convex', 'error_codes.json'),
      ),
    );
    final payloadBindings = await scanPayloadBindings(
      File(
        path.join(
          repositoryRoot,
          'lib',
          'collab',
          'convex_payload_codecs.dart',
        ),
      ),
    );
    final mapped = mapContract(contract, payloadBindings);
    final output = Directory(
      path.join(repositoryRoot, 'lib', 'collab', 'generated'),
    );
    final files = emitContract(mapped);
    writeGeneratedOutput(output, files);
    stdout.writeln(
      'Generated ${files.length} files for ${contract.functions.length} '
      'public Convex functions.',
    );
  } on ContractException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}

String _repositoryRoot(List<String> arguments) {
  if (arguments.isNotEmpty) {
    if (arguments.length != 2 || arguments.first != '--repository-root') {
      throw const FormatException(
        'Usage: dart run bin/generate.dart [--repository-root PATH]',
      );
    }
    return path.normalize(path.absolute(arguments[1]));
  }
  final packageRoot = path.dirname(path.dirname(Platform.script.toFilePath()));
  return path.normalize(path.join(packageRoot, '..', '..'));
}
