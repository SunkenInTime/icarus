import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';

/// Says what "+" could not finish at once, if anything (see
/// StrategyProvider.addPage).
void showNewPageGaps(NewPageGaps gaps) {
  if (gaps.waitingForCloud) {
    Settings.showToast(
      message: "The new page hasn't reached the cloud yet. It will appear "
          'once it does.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
    return;
  }
  if (gaps.unsavedEditsLeftOut) {
    Settings.showToast(
      message: "Changes to the page you copied that didn't save aren't in the "
          'copy.',
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }
  final images = gaps.imagesLeftOut;
  if (images > 0) {
    Settings.showToast(
      message: images == 1
          ? "An image was still uploading, so it isn't on the new page."
          : "$images images were still uploading, so they aren't on the new "
              'page.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }
}
