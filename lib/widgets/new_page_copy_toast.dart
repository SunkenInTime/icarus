import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';

/// Says what a new page's copy may lack, and when the page hasn't reached
/// the cloud yet, if either (see StrategyProvider.addPage).
void showNewPageGaps(NewPageGaps gaps) {
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
  final images = gaps.imagesUploading;
  if (images > 0) {
    Settings.showToast(
      message: images == 1
          ? 'An image on the page you copied was still uploading, so the '
              'copy may not have it.'
          : '$images images on the page you copied were still uploading, so '
              'the copy may not have them.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }
}
