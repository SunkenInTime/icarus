import 'package:flutter_riverpod/flutter_riverpod.dart';

final launchClock = Stopwatch();

sealed class FirstFrame {
  const FirstFrame();
}

final class FirstFrameNotYet extends FirstFrame {
  const FirstFrameNotYet();
}

final class FirstFrameDrawn extends FirstFrame {
  const FirstFrameDrawn(this.afterLaunch);

  final Duration afterLaunch;
}

final firstFrameProvider = StateProvider<FirstFrame>(
  (ref) => const FirstFrameNotYet(),
);
