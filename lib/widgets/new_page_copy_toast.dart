import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';

/// Says what a new page's copy lacks, and when the page hasn't reached
/// the cloud yet, if either (see StrategyProvider.addPage).
void showNewPageGaps(NewPageGaps gaps) {
  if (gaps.notSaved) {
    Settings.showToast(
      message: "The new page couldn't be saved on this computer, so it "
          "wasn't added.",
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }
  if (gaps.waitingForCloud) {
    Settings.showToast(
      message: "The new page hasn't reached the cloud yet. It will appear "
          'once it does.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }
  if (gaps.unsavedEdits) {
    Settings.showToast(
      message: "Changes to the page you copied that didn't save won't be in "
          'the copy.',
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }
}
