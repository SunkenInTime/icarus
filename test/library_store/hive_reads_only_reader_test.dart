import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _reader = 'lib/library_store/hive_reads.dart';
const _boxAccess = ['package:hive_ce', 'Hive.box', 'HiveBoxNames'];
const _rawReads = ['HiveReads.over', 'LibraryBoxes'];

List<String> _found(Iterable<File> files, List<String> needles) => [
      for (final file in files)
        for (final (index, line) in file.readAsLinesSync().indexed)
          for (final needle in needles)
            if (line.contains(needle))
              '${p.split(file.path).join('/')}:${index + 1} $needle',
    ];

Iterable<File> _dartFiles(String directory) => Directory(directory)
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'))
    .where((file) => p.split(file.path).join('/') != _reader);

void main() {
  test('only hive_reads.dart reaches the library boxes from the store code',
      () {
    expect(_found(_dartFiles('lib/library_store'), _boxAccess), isEmpty);
  });

  test('no app code reads the boxes around the in-flight check', () {
    expect(_found(_dartFiles('lib'), _rawReads), isEmpty);
  });

  test('the check sees a box reference when one is added', () {
    final scratch = Directory.systemTemp.createTempSync('icarus-reader-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final file = File(p.join(scratch.path, 'outside.dart'))
      ..writeAsStringSync(
          "final read = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);\n"
          'final raw = HiveReads.over(boxes);\n');
    expect(_found([file], _boxAccess), hasLength(2));
    expect(_found([file], _rawReads), hasLength(1));
  });
}
