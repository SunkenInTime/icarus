import 'package:icarus/const/settings.dart';

/// Says how many images a new page's copy left out, if any: in the cloud,
/// an image still uploading is not copied (see StrategyProvider.addPage).
void showImagesLeftOutOfNewPage(int imagesLeftOut) {
  if (imagesLeftOut == 0) return;
  Settings.showToast(
    message: imagesLeftOut == 1
        ? "An image was still uploading, so it isn't on the new page."
        : "$imagesLeftOut images were still uploading, so they aren't on "
            'the new page.',
    backgroundColor: Settings.tacticalVioletTheme.primary,
  );
}
