import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/canvas_clipboard_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/clipboard_service.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/canvas_paste.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

class _OpenStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'test-strategy',
        strategyName: null,
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  void setUnsaved() {}
}

class _Images extends PlacedImageProvider {
  final added = <Uint8List>[];

  @override
  Future<bool> addImageOnScreen(
    Uint8List imageBytes, {
    int? tagColorValue,
  }) async {
    added.add(imageBytes);
    return true;
  }
}

/// A clipboard holding copied items, or nothing.
class _Items extends CanvasClipboardNotifier {
  _Items({required this.holdsItems});

  final bool holdsItems;
  var pastes = 0;

  @override
  CanvasClipboard? build() => holdsItems
      ? CanvasClipboard(
          map: MapValue.ascent,
          strategyId: 'test-strategy',
          agents: const [],
          abilities: const [],
          texts: const [],
          images: const [],
          utilities: const [],
          drawings: const [],
          lineups: LineUpGraph.empty,
          pictures: Future.value(const {}),
        )
      : null;

  @override
  Future<PasteRefusal?> paste() async {
    pastes++;
    return null;
  }
}

void main() {
  final picture = Uint8List.fromList([1, 2, 3]);
  late _Images images;
  late _Items items;
  late int reads;
  late ProviderContainer container;

  Future<void> pumpEditor(
    WidgetTester tester, {
    required bool onClipboard,
    required bool holdsItems,
    Widget? content,
    Future<Uint8List>? saved,
    Future<void>? readDone,
    bool busy = false,
  }) async {
    images = _Images();
    items = _Items(holdsItems: holdsItems);
    reads = 0;
    container = ProviderContainer(
      overrides: [
        strategyProvider.overrideWith(_OpenStrategy.new),
        placedImageProvider.overrideWith(() => images),
        canvasClipboardProvider.overrideWith(() => items),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ToastificationWrapper(
          child: ShadApp(
            home: Shortcuts(
              shortcuts: ShortcutInfo.globalShortcutsFor(const {}),
              child: CanvasPaste(
                readPicture: () async {
                  reads++;
                  await readDone;
                  if (busy) throw ClipboardBusyException();
                  return onClipboard
                      ? ClipboardImage(picture, name: 'p', saved: saved)
                      : null;
                },
                child: Scaffold(
                  body: content ??
                      const Focus(autofocus: true, child: SizedBox.expand()),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pressPaste(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a picture on the clipboard lands on the page', (tester) async {
    await pumpEditor(tester, onClipboard: true, holdsItems: false);

    await pressPaste(tester);

    expect(images.added, [picture]);
  });

  testWidgets('a picture beats items copied before it', (tester) async {
    await pumpEditor(tester, onClipboard: true, holdsItems: true);

    await pressPaste(tester);

    expect(images.added, [picture]);
    expect(items.pastes, 0);
  });

  testWidgets('with no picture, copied items paste', (tester) async {
    await pumpEditor(tester, onClipboard: false, holdsItems: true);

    await pressPaste(tester);

    expect(images.added, isEmpty);
    expect(items.pastes, 1);
  });

  testWidgets('with nothing to paste, it says so', (tester) async {
    await pumpEditor(tester, onClipboard: false, holdsItems: false);

    await pressPaste(tester);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('No image found in clipboard'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a busy clipboard says so and pastes nothing', (tester) async {
    await pumpEditor(
      tester,
      onClipboard: true,
      holdsItems: true,
      busy: true,
    );

    await pressPaste(tester);
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.text(
        ClipboardService.busyMessage(
          lookupAppLocalizations(const Locale('en')),
        ),
      ),
      findsOneWidget,
    );
    expect(items.pastes, 0);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a drawing tool in hand goes down for a picture', (tester) async {
    await pumpEditor(tester, onClipboard: true, holdsItems: false);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.textTools);

    await pressPaste(tester);

    expect(images.added, [picture]);
    expect(
      container.read(interactionStateProvider),
      InteractionState.navigation,
    );
  });

  testWidgets('a picture that takes a moment says so, then lands',
      (tester) async {
    final saved = Completer<Uint8List>();
    await pumpEditor(
      tester,
      onClipboard: true,
      holdsItems: false,
      saved: saved.future,
    );

    await pressPaste(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Adding picture…'), findsOneWidget);

    saved.complete(picture);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(images.added, [picture]);
    expect(find.text('Adding picture…'), findsNothing);
  });

  testWidgets('a picture ready as the notice appears leaves no notice behind',
      (tester) async {
    final saved = Completer<Uint8List>();
    await pumpEditor(
      tester,
      onClipboard: true,
      holdsItems: false,
      saved: saved.future,
    );

    await pressPaste(tester);
    // Due with the notice, so it finishes before the notice's first frame.
    Timer(const Duration(milliseconds: 200), () => saved.complete(picture));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(images.added, [picture]);
    expect(find.text('Adding picture…'), findsNothing);
  });

  testWidgets('a lineup started meanwhile keeps the picture off the page',
      (tester) async {
    final saved = Completer<Uint8List>();
    await pumpEditor(
      tester,
      onClipboard: true,
      holdsItems: false,
      saved: saved.future,
    );

    await pressPaste(tester);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);
    saved.complete(picture);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(images.added, isEmpty);
    expect(
      find.text(
        'The page changed before the paste finished, so nothing was pasted.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
  });

  for (final onClipboard in [true, false]) {
    testWidgets(
        'a page left during the read keeps '
        '${onClipboard ? 'the picture' : 'copied items'} off the next one',
        (tester) async {
      final read = Completer<void>();
      await pumpEditor(
        tester,
        onClipboard: onClipboard,
        holdsItems: true,
        readDone: read.future,
      );
      final pages = container.read(strategyPageSessionProvider.notifier);
      void showPage(String id) => pages.setStateForTest(
            container
                .read(strategyPageSessionProvider)
                .copyWith(activePageId: id),
          );
      showPage('page-a');

      await pressPaste(tester);
      showPage('page-b');
      read.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(images.added, isEmpty);
      expect(items.pastes, 0);
      expect(
        find.text(
          'The page changed before the paste finished, so nothing was pasted.',
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
    });
  }

  testWidgets('a lineup being placed keeps the clipboard out', (tester) async {
    await pumpEditor(tester, onClipboard: true, holdsItems: true);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await pressPaste(tester);

    expect(reads, 0);
    expect(images.added, isEmpty);
  });

  testWidgets('a text field keeps its own paste', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, dynamic>{'text': 'typed'}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pumpEditor(
      tester,
      onClipboard: true,
      holdsItems: true,
      content: TextField(controller: controller, autofocus: true),
    );

    await pressPaste(tester);
    await tester.pumpAndSettle();

    expect(reads, 0);
    expect(controller.text, 'typed');
  });

  testWidgets('a dialog over the editor keeps the clipboard out',
      (tester) async {
    await pumpEditor(tester, onClipboard: true, holdsItems: true);
    showDialog<void>(
      context: tester.element(find.byType(Scaffold)),
      builder: (_) => const Focus(autofocus: true, child: SizedBox()),
    );
    await tester.pumpAndSettle();

    await pressPaste(tester);

    expect(reads, 0);
  });
}
