import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/onboarding/launch_intro.dart';

void main() {
  final plainPage = Uri.parse('https://icarus.example/');

  LaunchIntro plainLaunch({required bool firstLaunch}) => LaunchIntro.choose(
        asked: null,
        driveBuild: false,
        opensFileOrLink: false,
        firstLaunch: firstLaunch,
      );

  test('the first launch onboards and every later launch plays the splash', () {
    expect(plainLaunch(firstLaunch: true), LaunchIntro.onboarding);
    expect(plainLaunch(firstLaunch: false), LaunchIntro.splash);
  });

  test('a launch that opens a file or a link goes straight to it', () {
    for (final firstLaunch in [true, false]) {
      expect(
        LaunchIntro.choose(
          asked: null,
          driveBuild: false,
          opensFileOrLink: true,
          firstLaunch: firstLaunch,
        ),
        LaunchIntro.none,
      );
    }
  });

  test('a driver build shows no intro unless a launch asks for one', () {
    expect(
      LaunchIntro.choose(
        asked: null,
        driveBuild: true,
        opensFileOrLink: false,
        firstLaunch: true,
      ),
      LaunchIntro.none,
    );
    expect(
      LaunchIntro.choose(
        asked: LaunchIntro.onboarding,
        driveBuild: true,
        opensFileOrLink: true,
        firstLaunch: false,
      ),
      LaunchIntro.onboarding,
    );
  });

  test('the switch names an intro and is not passed on as a file', () {
    for (final intro in LaunchIntro.values) {
      final launch = LaunchIntroSwitch.parse(
        ['--intro=${intro.switchValue}', 'C:/plays/a-site.ica'],
        page: plainPage,
      );

      expect(launch.asked, intro);
      expect(launch.otherArgs, ['C:/plays/a-site.ica']);
    }
  });

  test('the web reads the switch from the address', () {
    final launch = LaunchIntroSwitch.parse(
      const [],
      page: Uri.parse('https://icarus.example/?intro=onboarding'),
    );

    expect(launch.asked, LaunchIntro.onboarding);
  });

  test('an intro nobody made asks for nothing', () {
    final launch = LaunchIntroSwitch.parse(
      const ['--intro=fireworks'],
      page: plainPage,
    );

    expect(launch.asked, isNull);
    expect(launch.otherArgs, isEmpty);
  });
}
