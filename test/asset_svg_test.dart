import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/asset_svg.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _svg = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
    '<rect width="10" height="10" fill="#fff"/></svg>';
const _notice = "Map didn't load";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // What the web engine does with no connection: the asset read comes back
  // empty and the bundle throws.
  var online = false;
  var reads = <String>[];

  setUp(() {
    online = false;
    reads = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      reads.add(utf8.decode(Uint8List.sublistView(message!)));
      return online
          ? ByteData.sublistView(Uint8List.fromList(utf8.encode(_svg)))
          : null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  Widget app(String asset) => ShadTheme(
        data: ShadThemeData(
          brightness: Brightness.dark,
          colorScheme: const ShadSlateColorScheme.dark(),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [AssetSvg(asset), MissingMapNotice(asset)],
          ),
        ),
      );

  // Decoding runs outside the test's fake clock, so give it real time, then a
  // frame to show the result.
  Future<void> settle(WidgetTester tester, [Duration? wait]) async {
    await tester.pump(wait);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  // The widget vector_graphics paints with, which exists only once a picture
  // has been decoded. SvgPicture itself is there from the first frame.
  final drawn = find.byWidgetPredicate(
    (widget) => '${widget.runtimeType}'.contains('VectorGraphicWidget'),
  );

  testWidgets('a failed read comes back by itself, with nothing thrown', (
    tester,
  ) async {
    await tester.pumpWidget(app('a_failed_read.svg'));
    await settle(tester);

    expect(find.text(_notice), findsOneWidget);
    expect(drawn, findsNothing);
    expect(reads, ['a_failed_read.svg']);

    // Still offline: each try is a real read, not a remembered failure.
    await settle(tester, AssetSvg.retryDelay);
    expect(reads, hasLength(2));
    expect(find.text(_notice), findsOneWidget);

    online = true;
    await settle(tester, AssetSvg.retryDelay);

    expect(reads, hasLength(3));
    expect(find.text(_notice), findsNothing);
    expect(drawn, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two pictures waiting on one asset both come back', (
    tester,
  ) async {
    await tester.pumpWidget(app('shared.svg'));
    await settle(tester);

    await tester.pumpWidget(
      Stack(
        textDirection: TextDirection.ltr,
        children: [app('shared.svg'), app('shared.svg')],
      ),
    );
    await settle(tester);

    online = true;
    await settle(tester, AssetSvg.retryDelay);

    expect(drawn, findsNWidgets(2));
    expect(find.text(_notice), findsNothing);
  });

  testWidgets('a picture left waiting is there when its widget returns', (
    tester,
  ) async {
    await tester.pumpWidget(app('left_and_back.svg'));
    await settle(tester);
    expect(find.text(_notice), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    online = true;
    await settle(tester, AssetSvg.retryDelay);

    await tester.pumpWidget(app('left_and_back.svg'));
    await settle(tester);
    expect(find.text(_notice), findsNothing);
    expect(drawn, findsOneWidget);
  });

  testWidgets('an asset that arrived still shows with no connection', (
    tester,
  ) async {
    online = true;
    await tester.pumpWidget(app('already_read.svg'));
    await settle(tester);
    online = false;
    reads.clear();

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app('already_read.svg'));
    await settle(tester);

    expect(drawn, findsOneWidget);
    expect(reads, isEmpty);
  });

  testWidgets('a side that fails does not leave the old side on screen', (
    tester,
  ) async {
    online = true;
    await tester.pumpWidget(app('attack.svg'));
    await settle(tester);
    expect(drawn, findsOneWidget);

    online = false;
    await tester.pumpWidget(app('defense.svg'));
    await settle(tester);

    expect(drawn, findsNothing);
    expect(find.text(_notice), findsOneWidget);

    // Let the read finish so its wait doesn't outlive the test.
    online = true;
    await settle(tester, AssetSvg.retryDelay);
  });
}
