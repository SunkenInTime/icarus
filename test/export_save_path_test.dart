import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/export_save_path.dart';
import 'package:path/path.dart' as p;

/// A save dialog that returns what the user typed, one answer per opening,
/// and keeps what it was asked to show.
class _SaveDialog extends FilePicker {
  _SaveDialog(this.answers);

  final List<String?> answers;
  final offered = <String?>[];
  final folders = <String?>[];

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    offered.add(fileName);
    folders.add(initialDirectory);
    return answers.removeAt(0);
  }
}

void main() {
  late Directory folder;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('icarus-export-path');
  });

  tearDown(() => folder.deleteSync(recursive: true));

  String inFolder(String name) => p.join(folder.path, name);

  group('chooseExportPath', () {
    test('gives a renamed file its extension back', () async {
      FilePicker.platform = _SaveDialog([inFolder('retakes')]);

      expect(await chooseExportPath('Plan.ica'), inFolder('retakes.ica'));
    });

    test('keeps a name that already ends right, however it is cased', () async {
      FilePicker.platform = _SaveDialog([inFolder('RETAKES.ICA')]);

      expect(await chooseExportPath('Plan.ica'), inFolder('RETAKES.ICA'));
    });

    test('adds to a name with a dot that is not the extension', () async {
      FilePicker.platform = _SaveDialog([inFolder('ascent v1.2')]);

      expect(await chooseExportPath('Plan.ica'), inFolder('ascent v1.2.ica'));
    });

    test('a cancelled dialog chooses nothing', () async {
      FilePicker.platform = _SaveDialog([null]);

      expect(await chooseExportPath('Plan.ica'), isNull);
    });

    test(
      'a corrected name that is taken goes back to the dialog to ask',
      () async {
        final taken = File(inFolder('retakes.ica'))..writeAsStringSync('mine');
        final dialog = _SaveDialog([inFolder('retakes'), taken.path]);
        FilePicker.platform = dialog;

        // The second answer is the dialog's own: it has asked about replacing.
        expect(await chooseExportPath('Plan.ica'), taken.path);
        expect(dialog.offered, ['Plan.ica', 'retakes.ica']);
        expect(dialog.folders, [null, folder.path]);
      },
    );
  });

  test('backing out of replacing a taken name keeps the file', () async {
    File(inFolder('retakes.png')).writeAsStringSync('mine');
    FilePicker.platform = _SaveDialog([inFolder('retakes'), null]);

    await saveExportBytes('Plan.png', Uint8List.fromList([1, 2, 3]));

    expect(File(inFolder('retakes.png')).readAsStringSync(), 'mine');
  });

  test('saveExportBytes writes under the corrected name alone', () async {
    FilePicker.platform = _SaveDialog([inFolder('retakes')]);

    await saveExportBytes('Plan.png', Uint8List.fromList([1, 2, 3]));

    expect(folder.listSync().map((file) => p.basename(file.path)), [
      'retakes.png',
    ]);
    expect(File(inFolder('retakes.png')).readAsBytesSync(), [1, 2, 3]);
  });
}
