import 'dart:io';

Directory? _folder;
Future<String>? _built;

Future<String> _executable() => _built ??= _build();

Future<String> _build() async {
  final folder = _folder = await Directory.systemTemp.createTemp(
    'icarus-library-process-',
  );
  final built = await Process.run(Platform.resolvedExecutable, [
    'build',
    'cli',
    '-t',
    'test/sqlite/library_process.dart',
    '-o',
    folder.path,
  ]);
  if (built.exitCode != 0) {
    throw StateError(
      'the library process did not build:\n${built.stdout}\n${built.stderr}',
    );
  }
  final name = Platform.isWindows ? 'library_process.exe' : 'library_process';
  return [folder.path, 'bundle', 'bin', name].join(Platform.pathSeparator);
}

Future<Process> startLibraryProcess(String mode, String path) async =>
    Process.start(await _executable(), [mode, path]);

Future<ProcessResult> runLibraryProcess(String mode, String path) async =>
    Process.run(await _executable(), [mode, path]);

Future<void> removeLibraryProcess() async {
  await _folder?.delete(recursive: true);
}
