import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';

/// Says what of the page on screen a new cloud page could not copy, if
/// anything (see StrategyProvider.addPage).
void showNewPageCopyGaps(NewPageCopyGaps? gaps) {
  if (gaps == null) return;
  if (gaps.pageNotAdded) {
    Settings.showToast(
      message: "Couldn't reach the cloud, so no page was added.",
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  } else if (gaps.notSaved) {
    Settings.showToast(
      message: "Couldn't save all of the page's copy on this device, so some "
          'of it is missing from the new page.',
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  } else if (gaps.imagesLeft > 0) {
    Settings.showToast(
      message: gaps.imagesLeft == 1
          ? "An image couldn't be copied yet, so it isn't on the new page."
          : "${gaps.imagesLeft} images couldn't be copied yet, so they aren't "
              'on the new page.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }
}
