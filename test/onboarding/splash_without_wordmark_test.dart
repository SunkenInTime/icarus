import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/onboarding/ignite_splash.dart';

class _NeverArrives extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) => Completer<ByteData>().future;
}

void main() {
  testWidgets('a wordmark that never arrives does not keep the app covered',
      (tester) async {
    var done = 0;
    var leaving = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultAssetBundle(
          bundle: _NeverArrives(),
          child: IgniteSplash(
            findHome: () => null,
            onDone: () => done++,
            onLeaving: () => leaving++,
            afterLoader: true,
          ),
        ),
      ),
    );

    await tester.pump(IgniteTimeline.glyphsWithin);
    expect(done, 1);
    expect(leaving, 1);
  });
}
