import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/widgets/ica_drop_target.dart';

void main() {
  test('summary uses folder-only success phrasing', () {
    final summary = buildImportSummaryMessage(
      const ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 1,
        issues: [],
      ),
    );

    expect(summary, 'Imported 1 folder.');
  });

  test('summary uses folder-only partial phrasing', () {
    final summary = buildImportSummaryMessage(
      const ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 1,
        issues: [
          ImportIssue(
            path: 'notes.txt',
            code: ImportIssueCode.unsupportedFile,
          ),
        ],
      ),
    );

    expect(summary, 'Imported 1 folder. Skipped 1 file.');
  });

  test('summary uses no-import wording when everything is skipped', () {
    final summary = buildImportSummaryMessage(
      const ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 0,
        issues: [
          ImportIssue(
            path: 'notes.txt',
            code: ImportIssueCode.unsupportedFile,
          ),
          ImportIssue(
            path: 'archive.zip',
            code: ImportIssueCode.unsupportedFile,
          ),
        ],
      ),
    );

    expect(
      summary,
      'No compatible strategies or folders were imported. Skipped 2 files.',
    );
  });

  test('summary uses mixed success phrasing for clean imports', () {
    final summary = buildImportSummaryMessage(
      const ImportBatchResult(
        strategiesImported: 10,
        foldersCreated: 3,
        issues: [],
      ),
    );

    expect(summary, 'Imported 10 strategies into 3 folders.');
  });

  group('files from a newer Icarus ask for the update', () {
    const newer = ImportIssue(
      path: 'future.ica',
      code: ImportIssueCode.newerVersion,
    );
    const unsupported = ImportIssue(
      path: 'notes.txt',
      code: ImportIssueCode.unsupportedFile,
    );
    ImportBatchResult resultOf(int strategies, List<ImportIssue> issues) =>
        ImportBatchResult(
          strategiesImported: strategies,
          foldersCreated: 0,
          issues: issues,
        );

    test('one file, and nothing else', () {
      expect(
        buildImportSummaryMessage(resultOf(0, const [newer])),
        NewerVersionImportException.userMessage,
      );
    });

    test('several files, and nothing else', () {
      expect(
        buildImportSummaryMessage(resultOf(0, const [newer, newer])),
        'These strategies were created in a newer version of Icarus. '
        'Please update the app and try again.',
      );
    });

    test('beside files that did import', () {
      expect(
        buildImportSummaryMessage(resultOf(2, const [newer])),
        'Imported 2 strategies. Skipped 1 file. 1 was created in a newer '
        'version of Icarus. Please update the app and try again.',
      );
    });

    test('beside files that could never import', () {
      expect(
        buildImportSummaryMessage(
          resultOf(0, const [newer, newer, unsupported]),
        ),
        'No compatible strategies or folders were imported. Skipped 3 files. '
        '2 were created in a newer version of Icarus. '
        'Please update the app and try again.',
      );
    });
  });

  test('summary mentions restored library globals', () {
    final summary = buildImportSummaryMessage(
      const ImportBatchResult(
        strategiesImported: 2,
        foldersCreated: 1,
        themeProfilesImported: 1,
        globalStateRestored: true,
        issues: [],
      ),
    );

    expect(
      summary,
      'Imported 2 strategies into 1 folder. Imported 1 theme profile. Restored library settings.',
    );
  });
}
