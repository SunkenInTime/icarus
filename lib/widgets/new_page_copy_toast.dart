import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/strategy_provider.dart';

/// Says what a new page's copy lacks, and when the page hasn't reached
/// the cloud yet, if either (see StrategyProvider.addPage).
void showNewPageGaps(AppLocalizations l10n, NewPageGaps gaps) {
  if (gaps.notSaved) {
    Settings.showToast(
      message: l10n.newPageCopyNotSaved,
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }
  if (gaps.waitingForCloud) {
    Settings.showToast(
      message: l10n.newPageCopyWaitingForCloud,
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }
  if (gaps.unsavedEdits) {
    Settings.showToast(
      message: l10n.newPageCopyUnsavedEdits,
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }
}
