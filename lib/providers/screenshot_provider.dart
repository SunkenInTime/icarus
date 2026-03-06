import 'package:flutter_riverpod/flutter_riverpod.dart';

final screenshotProvider = NotifierProvider<ScreenshotProvider, bool>(
  ScreenshotProvider.new,
);

class ScreenshotProvider extends Notifier<bool> {
  @override
  bool build() {
    return false;
  }

  setIsScreenShot(bool isScreenshot) {
    state = isScreenshot;
  }
}

