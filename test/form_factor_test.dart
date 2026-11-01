import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/form_factor.dart';

void main() {
  FormFactor formFactorOn(TargetPlatform platform, Size window) {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    return FormFactor.forWindow(window, isWeb: true);
  }

  group('FormFactor', () {
    test('a desktop window is desktop at any size', () {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        expect(
            formFactorOn(platform, const Size(320, 568)), FormFactor.desktop);
        expect(
          formFactorOn(platform, const Size(1920, 1080)),
          FormFactor.desktop,
        );
      }
    });

    test('nothing outside the web build changes', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(
        FormFactor.forWindow(const Size(390, 664), isWeb: false),
        FormFactor.desktop,
      );
    });

    test('a phone is a phone either way up', () {
      expect(
        formFactorOn(TargetPlatform.iOS, const Size(390, 664)),
        FormFactor.phone,
      );
      expect(
        formFactorOn(TargetPlatform.android, const Size(915, 412)),
        FormFactor.phone,
      );
    });

    test('only an upright phone covers the editor', () {
      const upright = Size(390, 664);
      const sideways = Size(750, 340);
      expect(FormFactor.phone.coversEditor(upright), isTrue);
      expect(FormFactor.phone.coversEditor(sideways), isFalse);
      expect(FormFactor.tablet.coversEditor(upright), isFalse);
      expect(FormFactor.desktop.coversEditor(upright), isFalse);
    });

    test('a tablet is a tablet either way up', () {
      expect(
        formFactorOn(TargetPlatform.iOS, const Size(768, 1024)),
        FormFactor.tablet,
      );
      expect(
        formFactorOn(TargetPlatform.android, const Size(1194, 834)),
        FormFactor.tablet,
      );
    });
  });
}
