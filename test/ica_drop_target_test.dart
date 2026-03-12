import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/strategy_provider.dart';
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
}
