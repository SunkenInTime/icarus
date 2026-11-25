import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum LaunchIntro {
  onboarding('onboarding'),
  splash('splash'),
  none('none');

  const LaunchIntro(this.switchValue);

  final String switchValue;

  static LaunchIntro? named(String? value) {
    for (final intro in values) {
      if (intro.switchValue == value) return intro;
    }
    return null;
  }

  static LaunchIntro choose({
    required LaunchIntro? asked,
    required bool driveBuild,
    required bool opensFileOrLink,
    required bool firstLaunch,
  }) {
    if (asked != null) return asked;
    if (driveBuild || opensFileOrLink) return none;
    return firstLaunch ? onboarding : splash;
  }
}

final class LaunchIntroRun {
  const LaunchIntroRun(this.intro, {this.take = 0});

  final LaunchIntro intro;
  final int take;
}

final launchIntroProvider = StateProvider<LaunchIntroRun?>((ref) => null);

Future<void> untilLaunchIntroEnds(ProviderContainer container) async {
  if (container.read(launchIntroProvider) == null) return;
  final ended = Completer<void>();
  final watching = container.listen(launchIntroProvider, (_, run) {
    if (run == null && !ended.isCompleted) ended.complete();
  });
  await ended.future;
  watching.close();
}

final class LaunchIntroSwitch {
  const LaunchIntroSwitch._(this.asked, this.otherArgs);

  static const option = '--intro';
  static const queryParameter = 'intro';

  final LaunchIntro? asked;
  final List<String> otherArgs;

  static LaunchIntroSwitch parse(List<String> args, {required Uri page}) {
    var value = page.queryParameters[queryParameter];
    final others = <String>[];
    for (final argument in args) {
      if (argument.startsWith('$option=')) {
        value = argument.substring(option.length + 1);
      } else {
        others.add(argument);
      }
    }
    return LaunchIntroSwitch._(
      LaunchIntro.named(value),
      List.unmodifiable(others),
    );
  }
}
