import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/asset_svg.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _svg = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
    '<rect width="10" height="10" fill="#fff"/></svg>';

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
        .setMockMessageHandler('flutter/assets', (message) {
      reads.add(utf8.decode(Uint8List.sublistView(message!)));
      return SynchronousFuture(
        online
            ? ByteData.sublistView(Uint8List.fromList(utf8.encode(_svg)))
            : null,
      );
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

  // A read finishes during one pump and its setState builds in the next.
  Future<void> settle(WidgetTester tester, [Duration? wait]) async {
    await tester.pump(wait);
    await tester.pump();
  }

  testWidgets('a failed read comes back by itself, with nothing thrown', (
    tester,
  ) async {
    await tester.pumpWidget(app('a_failed_read.svg'));
    await settle(tester);

    expect(find.text("Map didn't load"), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
    expect(reads, ['a_failed_read.svg']);

    // Still offline: each try is a real read, not a remembered failure.
    await settle(tester, AssetSvg.retryDelay);
    expect(reads, hasLength(2));
    expect(find.text("Map didn't load"), findsOneWidget);

    online = true;
    await settle(tester, AssetSvg.retryDelay);

    expect(reads, hasLength(3));
    expect(find.text("Map didn't load"), findsNothing);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(tester.takeException(), isNull);
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

    expect(find.byType(SvgPicture), findsOneWidget);
    expect(reads, isEmpty);
  });

  testWidgets('a side that fails drops the old side instead of keeping it', (
    tester,
  ) async {
    online = true;
    await tester.pumpWidget(app('attack.svg'));
    await settle(tester);
    expect(find.byType(SvgPicture), findsOneWidget);

    online = false;
    await tester.pumpWidget(app('defense.svg'));
    // The old side stays up while the new one is on its way.
    expect(find.byType(SvgPicture), findsOneWidget);

    await settle(tester);
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.text("Map didn't load"), findsOneWidget);

    // Leaving before the next try cancels it.
    await tester.pumpWidget(const SizedBox());
  });
}
