import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/screenshot/offscreen_capture.dart';

void main() {
  testWidgets('a capture does not tell the browser the page moved',
      (tester) async {
    // On web the address is where a reload reopens the editor. The capture
    // shell used to be an app with its own navigator, which reported `/` as
    // the page's route: after a screenshot, a reload opened the library.
    final reported = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.navigation,
      (call) async {
        if (call.method == 'routeInformationUpdated') {
          reported.add((call.arguments as Map)['uri'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.navigation, null),
    );

    late BuildContext captured;
    await tester.pumpWidget(wrapForOffscreenCapture(
      Builder(builder: (context) {
        captured = context;
        return const Text('captured view');
      }),
    ));
    await tester.pump();

    expect(find.text('captured view'), findsOneWidget);
    expect(reported, isEmpty);
    // What the captured view still gets from the shell.
    expect(Navigator.maybeOf(captured), isNotNull);
    expect(Overlay.maybeOf(captured), isNotNull);
    expect(ModalRoute.of(captured), isNotNull);
  });
}
