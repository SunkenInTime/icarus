import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/clipboard_service.dart';
import 'package:icarus/widgets/dialogs/upload_image_dialog.dart';
import 'package:image/image.dart' as img;
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  late Completer<Uint8List> saved;
  late Uint8List shown;
  late List<UploadImageResult?> results;

  Future<void> openDialog(WidgetTester tester) async {
    saved = Completer<Uint8List>();
    shown = img.encodePng(img.Image(width: 4, height: 4));
    results = [];
    await tester.pumpWidget(
      ProviderScope(
        child: ShadApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () async {
                        results.add(
                          await showShadDialog<UploadImageResult?>(
                            context: context,
                            builder: (_) => UploadImageDialog(
                              readClipboard: () async => ClipboardImage(
                                shown,
                                name: 'Clipboard File',
                                saved: saved.future,
                              ),
                            ),
                          ),
                        );
                      },
                      child: const Text('The editor'),
                    ),
                  ),
                ),
              ),
              child: const Text('The library'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('The library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The editor'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('Use image hands over the saved bytes once they are ready',
      (tester) async {
    await openDialog(tester);
    await tester.tap(find.text('Use image'));
    await tester.pump();
    expect(results, isEmpty);

    final png = Uint8List.fromList([1, 2, 3]);
    saved.complete(png);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(results.single!.bytes, same(png));
  });

  testWidgets('a route opened over the dialog during the wait is left alone',
      (tester) async {
    await openDialog(tester);
    final png = Uint8List.fromList([1, 2, 3]);
    await tester.tap(find.text('Use image'));
    await tester.pump();

    final navigator = Navigator.of(tester.element(find.text('Use image')));
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const Text('The color picker')),
    );
    await tester.pumpAndSettle();
    saved.complete(png);
    await tester.pumpAndSettle();
    expect(find.text('The color picker'), findsOneWidget);
    expect(results, isEmpty);

    navigator.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use image'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(results.single!.bytes, same(png));
  });

  testWidgets('Cancel during the wait closes only the dialog', (tester) async {
    await openDialog(tester);
    await tester.tap(find.text('Use image'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    // The encode finishes while the dialog is still animating away.
    saved.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('The editor'), findsOneWidget);
    expect(results, [null]);
  });
}
