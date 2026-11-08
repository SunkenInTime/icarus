import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/caption_links.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/caption_card.dart';
import 'package:icarus/widgets/caption_markers.dart';
import 'package:icarus/widgets/draggable_widgets/caption_menu.dart';

class _TestStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => StrategyState(
        isSaved: true,
        stratName: null,
        id: 'caption-ui-test',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

class _Preferences extends AppPreferencesNotifier {
  _Preferences(this.showCaptions);

  final bool showCaptions;

  @override
  AppPreferences build() => AppPreferences(
        defaultThemeProfileIdForNewStrategies: 'theme',
        showCaptions: showCaptions,
      );
}

ProviderContainer _container({bool showCaptions = true}) {
  final container = ProviderContainer(overrides: [
    strategyProvider.overrideWith(_TestStrategyProvider.new),
    appPreferencesProvider.overrideWith(() => _Preferences(showCaptions)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void _place(ProviderContainer container, {String? caption}) {
  container.read(agentProvider.notifier).fromHive([
    PlacedAgent(id: 'agent', type: AgentType.jett, position: Offset.zero)
      ..caption = caption,
  ]);
}

void main() {
  group('caption links', () {
    List<String?> links(String text) => [
          for (final run in captionRuns(text))
            if (run.uri != null) run.uri.toString(),
        ];

    test('runs join back to exactly what was typed', () {
      const text = 'Watch https://youtu.be/9vxdjCd272k?t=330, then www.a.gg.';
      expect(captionRuns(text).map((run) => run.text).join(), text);
    });

    test('a timestamp survives, and the sentence around it stays out', () {
      expect(links('See https://youtu.be/9vxdjCd272k?si=Rr&t=330.'), [
        'https://youtu.be/9vxdjCd272k?si=Rr&t=330',
      ]);
    });

    test('bare forms open over https', () {
      expect(links('www.valorant.gg'), ['https://www.valorant.gg']);
      expect(links('youtu.be/abc'), ['https://youtu.be/abc']);
      expect(links('youtube.com/watch?v=abc'), [
        'https://youtube.com/watch?v=abc',
      ]);
    });

    test('an address built to mislead stays plain text', () {
      expect(links('https://trusted.example@other.example/x'), isEmpty);
    });

    test('text with no link is one plain run', () {
      expect(captionRuns('Fake A first').single.uri, isNull);
    });
  });

  group('a marker', () {
    test('hangs on the corner furthest up and right, however the item turns',
        () {
      const square = [
        Offset(0, 0),
        Offset(10, 0),
        Offset(10, 10),
        Offset(0, 10),
      ];
      expect(captionMarkerAnchor(square, round: false), const Offset(10, 0));
      const turned = [
        Offset(2, -1),
        Offset(12, 1),
        Offset(10, 11),
        Offset(0, 9),
      ];
      expect(captionMarkerAnchor(turned, round: false), const Offset(12, 1));
    });

    test('sits on the edge of a round item', () {
      const circle = [
        Offset(0, 0),
        Offset(20, 0),
        Offset(20, 20),
        Offset(0, 20),
      ];
      final anchor = captionMarkerAnchor(circle, round: true);
      expect((anchor - const Offset(10, 10)).distance, closeTo(10, 0.001));
    });

    test('lands on whole device pixels', () {
      for (final ratio in [1.0, 1.25, 1.5, 2.0]) {
        final origin = captionMarkerOrigin(const Offset(100.3, 40.7), ratio);
        expect(origin.dx * ratio, closeTo((origin.dx * ratio).round(), 1e-9));
        expect(origin.dy * ratio, closeTo((origin.dy * ratio).round(), 1e-9));
      }
    });
  });

  group('the card', () {
    test('opens after the pointer rests, not on the way past', () {
      fakeAsync((async) {
        final container = _container();
        _place(container, caption: 'Note');
        final card = container.read(captionCardProvider.notifier);

        card.itemEntered('agent', 'region');
        async.elapse(const Duration(milliseconds: 299));
        expect(container.read(captionCardProvider), isNull);
        card.itemExited('region');
        async.elapse(const Duration(seconds: 1));
        expect(container.read(captionCardProvider), isNull);

        card.itemEntered('agent', 'region');
        async.elapse(CaptionCardNotifier.openDelay);
        expect(container.read(captionCardProvider)?.id, 'agent');
      });
    });

    test('an item with no caption, or an empty one, opens nothing', () {
      fakeAsync((async) {
        final container = _container();
        _place(container, caption: '');
        container
            .read(captionCardProvider.notifier)
            .itemEntered('agent', 'region');
        async.elapse(const Duration(seconds: 1));
        expect(container.read(captionCardProvider), isNull);
      });
    });

    test('opens nothing with Show captions off', () {
      fakeAsync((async) {
        final container = _container(showCaptions: false);
        _place(container, caption: 'Note');
        final card = container.read(captionCardProvider.notifier);

        card.itemEntered('agent', 'region');
        async.elapse(const Duration(seconds: 1));
        card.openNow('agent');

        expect(container.read(captionCardProvider), isNull);
      });
    });

    test('stays open on the way from the item to the card', () {
      fakeAsync((async) {
        final container = _container();
        _place(container, caption: 'Note');
        final card = container.read(captionCardProvider.notifier);
        card.itemEntered('agent', 'region');
        async.elapse(CaptionCardNotifier.openDelay);

        card.itemExited('region');
        async.elapse(const Duration(milliseconds: 100));
        card.cardEntered();
        async.elapse(const Duration(seconds: 1));
        expect(container.read(captionCardProvider)?.id, 'agent');

        card.cardExited();
        async.elapse(CaptionCardNotifier.closeDelay);
        expect(container.read(captionCardProvider), isNull);
      });
    });

    test("a shape's center marker doesn't count as leaving the shape", () {
      fakeAsync((async) {
        final container = _container();
        _place(container, caption: 'Note');
        final card = container.read(captionCardProvider.notifier);
        card.itemEntered('agent', 'shape');
        card.itemEntered('agent', 'center marker');
        async.elapse(CaptionCardNotifier.openDelay);

        card.itemExited('center marker');
        async.elapse(const Duration(seconds: 1));
        expect(container.read(captionCardProvider)?.id, 'agent');
      });
    });

    test('a region removed under the pointer leaves nothing behind', () {
      fakeAsync((async) {
        final container = _container();
        _place(container, caption: 'Note');
        final card = container.read(captionCardProvider.notifier);
        // Deleted while hovered: Flutter reports no exit.
        card.itemEntered('agent', 'deleted region');
        card.itemExited('deleted region');

        // Undone, then hovered and left as usual.
        card.itemEntered('agent', 'new region');
        async.elapse(CaptionCardNotifier.openDelay);
        card.itemExited('new region');
        async.elapse(CaptionCardNotifier.closeDelay);

        expect(container.read(captionCardProvider), isNull);
      });
    });

    Future<ProviderContainer> pumpLayer(WidgetTester tester) async {
      final container = _container();
      _place(container, caption: 'Note');
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Stack(
              children: [
                Positioned.fill(
                  child: CaptionCardLayer(transformation: controller),
                ),
              ],
            ),
          ),
        ),
      );
      return container;
    }

    testWidgets('a real press cancels a card that was about to open',
        (tester) async {
      final container = await pumpLayer(tester);
      container
          .read(captionCardProvider.notifier)
          .itemEntered('agent', 'region');
      await tester.pump(const Duration(milliseconds: 100));

      final press = await tester.startGesture(const Offset(50, 50));
      await tester.pump(const Duration(seconds: 1));
      await press.up();
      await tester.pump();

      expect(container.read(captionCardProvider), isNull);
    });

    testWidgets('nothing opens under a held press, a marquee passing over',
        (tester) async {
      final container = await pumpLayer(tester);
      final press = await tester.startGesture(const Offset(50, 50));
      await tester.pump();

      container
          .read(captionCardProvider.notifier)
          .itemEntered('agent', 'region');
      await tester.pump(const Duration(seconds: 1));

      expect(container.read(captionCardProvider), isNull);
      await press.up();
      await tester.pump();
    });

    testWidgets('Escape cancels a card that was about to open', (tester) async {
      final container = await pumpLayer(tester);
      container
          .read(captionCardProvider.notifier)
          .itemEntered('agent', 'region');
      await tester.pump(const Duration(milliseconds: 100));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(seconds: 1));

      expect(container.read(captionCardProvider), isNull);
    });
  });

  group('editing a caption', () {
    late ProviderContainer container;

    setUp(() {
      container = _container();
      container.read(agentProvider.notifier).fromHive([
        PlacedAgent(id: 'agent', type: AgentType.jett, position: Offset.zero),
      ]);
      container.read(abilityProvider.notifier).fromHive([
        PlacedAbility(
          id: 'ability',
          data: AgentData.agents[AgentType.breach]!.abilities.first,
          position: Offset.zero,
        ),
      ]);
      container
          .read(textProvider.notifier)
          .fromHive([PlacedText(position: Offset.zero, id: 'text')]);
      container.read(placedImageProvider.notifier).fromHive([
        PlacedImage(
          position: Offset.zero,
          id: 'image',
          aspectRatio: 1,
          scale: 100,
          fileExtension: '.png',
        ),
      ]);
      container.read(utilityProvider.notifier).fromHive([
        PlacedUtility(
          type: UtilityType.spike,
          position: Offset.zero,
          id: 'spike',
        ),
      ]);
    });

    for (final id in ['agent', 'ability', 'text', 'image', 'spike']) {
      test('$id: a caption undoes to empty, not to nothing, and redoes', () {
        final actions = container.read(actionProvider.notifier);

        setCaption(container, id, 'Note');
        expect(placedItemById(container, id)!.caption, 'Note');

        actions.undoAction();
        // Left out, the server would keep the note (keepLaterFields).
        expect(placedItemById(container, id)!.caption, '');
        expect(placedItemById(container, id)!.toJson().containsKey('caption'),
            isTrue);

        actions.redoAction();
        expect(placedItemById(container, id)!.caption, 'Note');
      });
    }

    test("a note finished after its page changed isn't written", () {
      const elsewhere = (strategyId: 'other', pageId: 'other-page');

      final saved = finishCaption(container, 'agent', elsewhere, 'Note');

      expect(saved, isFalse);
      expect(placedItemById(container, 'agent')!.caption, isNull);
    });

    test("a note finished after its item was deleted isn't written", () {
      final here = currentCaptionPlace(container);

      expect(finishCaption(container, 'gone', here, 'Note'), isFalse);
      expect(finishCaption(container, 'agent', here, 'Note'), isTrue);
      expect(placedItemById(container, 'agent')!.caption, 'Note');
    });

    test('an edit that changes nothing leaves nothing to undo', () {
      final before = container.read(actionProvider).length;
      setCaption(container, 'agent', '');
      expect(container.read(actionProvider).length, before);
      expect(placedItemById(container, 'agent')!.caption, isNull);
    });
  });
}
