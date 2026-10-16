import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_drawing.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/widgets/replay/replay_dock.dart';
import 'package:icarus/widgets/replay/replay_events.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'replay_test_support.dart';

const _jett = 'add6443a-41bd-e414-f6ad-e58d267f4e95';
const _omen = '8e253930-4c05-31dd-1b6c-968525494517';

/// A match of [count] 10-second rounds, Red watched: Red attacks the first
/// twelve, Blue the next twelve, then sides swap every overtime round. Each
/// round ends the [ends] way at its index, round robin, and Red wins the
/// even ones. [first] adds to the first round.
ReplayPlayback _match(
  int count, {
  List<ReplayRoundEnd> ends = ReplayRoundEnd.values,
  List<Map<String, Object?>> kills = const [],
  Map<String, Object?> first = const {},
}) {
  String attacking(int i) => i < 12
      ? 'Red'
      : i < 24
          ? 'Blue'
          : i.isEven
              ? 'Red'
              : 'Blue';
  final document = ReplayDocument.fromBytes(icrp({
    ...sampleJson(),
    'match': {
      'id': 'match',
      'mapPath': '/Game/Maps/Juliett/Juliett',
      'build': '++Ares-Core+release-13.00',
      'durationMs': count * 10000,
    },
    'players': [
      {'subject': 'a', 'agentId': _jett, 'team': 'Red'},
      {'subject': 'b', 'agentId': _omen, 'team': 'Blue'},
    ],
    'rounds': [
      for (var i = 0; i < count; i++)
        {
          'index': i,
          'startMs': i * 10000,
          'combatStartMs': i * 10000 + 1000,
          'endMs': (i + 1) * 10000,
          'attackingTeam': attacking(i),
          'winningTeam': i.isEven ? 'Red' : 'Blue',
          'endReason': ends[i % ends.length].name,
          if (i == 0) ...first,
        },
    ],
    'kills': kills,
    'utility': [],
    'vitals': {},
  }));
  return ReplayPlayback(
    document: document,
    projection: ReplayMapProjection.forMapPath('/Game/Maps/Juliett/Juliett')!,
    perspective: ReplayTeam.red,
  );
}

Future<void> _pumpDock(
  WidgetTester tester,
  ReplayPlayback playback, {
  ReplayDrawing? drawing,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      child: ShadApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ReplayDock(playback: playback, drawing: drawing),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// An image of [path] in the dock.
Finder _asset(String path) => find.descendant(
      of: find.byType(ReplayDock),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName == path,
      ),
    );

/// The rounds the rail numbers, as it reads left to right.
List<String> _railNumbers(WidgetTester tester) {
  final labels = [
    for (final element in find
        .descendant(
          of: find.byType(ReplayDock),
          matching: find.byWidgetPredicate(
            (widget) => widget is Text && widget.style?.fontSize == 8,
          ),
        )
        .evaluate())
      (element.widget as Text),
  ];
  return [for (final label in labels) label.data!];
}

Finder get _playbackRow => find.ancestor(
      of: find.byWidgetPredicate((widget) =>
          widget is CustomPaint &&
          widget.painter.runtimeType.toString() == '_ScrubberPainter'),
      matching: find.byWidgetPredicate(
        (widget) => widget is Container && widget.decoration is BoxDecoration,
      ),
    );

void main() {
  testWidgets("each slot shows Valorant's art for how its round ended",
      (tester) async {
    final playback = _match(5);
    await _pumpDock(tester, playback);

    final slots = [
      for (final element in find
          .descendant(
            of: find.byType(ReplayDock),
            matching: find.byWidgetPredicate(
                (widget) => widget is Image && widget.image is AssetImage),
          )
          .evaluate())
        (element.widget as Image).image as AssetImage,
    ];
    // Left to right, the match's rounds as _match ends them.
    expect([
      for (final image in slots) image.assetName
    ], [
      'assets/replay/round-elimination.png',
      'assets/replay/round-detonated.png',
      'assets/replay/round-defused.png',
      'assets/replay/round-time.png',
      'assets/replay/round-surrender.png',
    ]);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
        tester.getCenter(_asset(replayRoundEndAsset(ReplayRoundEnd.defused))));
    await tester.pumpAndSettle();
    expect(find.text('Round 3 · Won · Spike defused'), findsOneWidget);

    await tester.tap(_asset(replayRoundEndAsset(ReplayRoundEnd.time)));
    await tester.pump();
    expect(playback.round?.index, 3);
  });

  testWidgets('the rail numbers the landmark rounds', (tester) async {
    await _pumpDock(tester, _match(21));
    expect(_railNumbers(tester), ['1', '5', '10', '13', '15', '20']);
    expect(find.text('OT'), findsNothing);

    await _pumpDock(tester, _match(30));
    expect(
      _railNumbers(tester),
      ['1', '5', '10', '13', '15', '20', '25', '30'],
    );
    // Overtime is marked once, though sides swap every round of it.
    expect(find.text('OT'), findsOneWidget);
    final ot = tester.getCenter(find.text('OT')).dx;
    final round25 = tester.getCenter(find.text('25')).dx;
    final round24 = tester
        .getCenter(_asset(replayRoundEndAsset(ReplayRoundEnd.time)).at(4))
        .dx;
    expect(ot, greaterThan(round24));
    expect(ot, lessThan(round25));
  });

  testWidgets('hiding the rounds keeps the playback row where it was',
      (tester) async {
    await _pumpDock(tester, _match(24));
    final row = tester.getRect(_playbackRow.first);
    final strip = tester.getRect(find.byType(SingleChildScrollView));
    // Both rows share their edges, the slots' width.
    expect(row.width, greaterThan(ReplayDock.minPlaybackWidth));
    expect(strip.left - row.left, closeTo(6, 0.01));
    expect(row.right - strip.right, closeTo(6, 0.01));

    final hide = tester.getCenter(find.byIcon(LucideIcons.chevronDown));
    await tester.tap(find.byIcon(LucideIcons.chevronDown));
    await tester.pump();
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.getRect(_playbackRow.first), row);
    // The same switch, in the same place, brings them back.
    expect(tester.getCenter(find.byIcon(LucideIcons.chevronUp)), hide);
    await tester.tap(find.byIcon(LucideIcons.chevronUp));
    await tester.pump();
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.getRect(_playbackRow.first), row);
  });

  testWidgets('a short match keeps a usable scrubber', (tester) async {
    await _pumpDock(tester, _match(13));
    final row = tester.getRect(_playbackRow.first);
    final strip = tester.getRect(find.byType(SingleChildScrollView));
    expect(row.width, ReplayDock.minPlaybackWidth);
    // The strip hugs its slots, centred over playback.
    expect(strip.width, lessThan(row.width - 100));
    expect(strip.center.dx, closeTo(row.center.dx, 0.01));
  });

  testWidgets('the story puts our kills above the line, theirs below',
      (tester) async {
    final playback = _match(2, kills: [
      {'timeMs': 4000, 'victim': 'b', 'killer': 'a'},
      {'timeMs': 7000, 'victim': 'a', 'killer': 'b'},
    ])
      ..seek(5000);
    await _pumpDock(tester, playback);
    Finder portrait(String agent) => find.descendant(
          of: find.byType(ReplayDock),
          matching: find.byWidgetPredicate((widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName ==
                  'assets/agents/$agent/icon.webp'),
        );
    expect(portrait('Jett'), findsNothing);

    await tester.tap(find.byIcon(LucideIcons.pin));
    await tester.pump();
    final track = tester.getRect(find.byWidgetPredicate((widget) =>
        widget is CustomPaint &&
        widget.painter.runtimeType.toString() == '_ScrubberPainter'));
    expect(track.height, 54);
    final jett = tester.getRect(portrait('Jett'));
    final omen = tester.getRect(portrait('Omen'));
    expect(jett.bottom, lessThanOrEqualTo(track.center.dy));
    expect(omen.top, greaterThanOrEqualTo(track.center.dy));
    // Each over its own kill's moment.
    expect(jett.center.dx, closeTo(track.left + track.width * 0.4, 1));
    expect(omen.center.dx, closeTo(track.left + track.width * 0.7, 1));

    // Hovering a killer shows the kill's killfeed line.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(omen.center);
    await tester.pump();
    final line = tester.widget<ReplayEventLine>(find.byType(ReplayEventLine));
    expect(line.event.kill?.killer, 'b');

    // The lower lane reaches below the line's own height; its last pixels
    // still answer, the ring around the portrait too.
    await mouse.moveTo(Offset(omen.center.dx, omen.bottom + 1));
    await tester.pump();
    expect(
      tester.widget<ReplayEventLine>(find.byType(ReplayEventLine)).event,
      line.event,
    );
    await tester.tapAt(Offset(omen.center.dx, omen.bottom + 1));
    await tester.pump();
    expect(playback.timeMs, 7000);

    // Watched from the other side, the lanes swap.
    await mouse.moveTo(Offset.zero);
    playback.perspective = ReplayTeam.blue;
    await tester.pump();
    expect(tester.getRect(portrait('Jett')).top,
        greaterThanOrEqualTo(track.center.dy));
    expect(tester.getRect(portrait('Omen')).bottom,
        lessThanOrEqualTo(track.center.dy));

    await tester.tap(find.byIcon(LucideIcons.pin));
    await tester.pump();
    expect(portrait('Jett'), findsNothing);
  });

  testWidgets(
      "a spike mark at the round's end stays on the track, and the one "
      'on top answers the pointer', (tester) async {
    // A plant half a second before the defuse that ends the round: their
    // circles overlap, and the defuse sits on the track's last pixel.
    final playback = _match(2, ends: [
      ReplayRoundEnd.elimination
    ], first: {
      'plant': {'timeMs': 9500, 'site': 'A', 'subject': 'a'},
      'defuse': {'timeMs': 10000, 'subject': 'b'},
    })
      ..seek(5000);
    await _pumpDock(tester, playback);
    await tester.tap(find.byIcon(LucideIcons.pin));
    await tester.pump();
    final track = tester.getRect(find.byWidgetPredicate((widget) =>
        widget is CustomPaint &&
        widget.painter.runtimeType.toString() == '_ScrubberPainter'));
    final defuse =
        tester.getRect(_asset(replayRoundEndAsset(ReplayRoundEnd.defused)));
    expect(defuse.right, lessThanOrEqualTo(track.right - 4));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(defuse.center);
    await tester.pump();
    final line = tester.widget<ReplayEventLine>(find.byType(ReplayEventLine));
    expect(line.event.kind, ReplayEventKind.defuse);

    await tester.tapAt(defuse.center);
    await tester.pump();
    expect(playback.timeMs, 10000);
  });

  testWidgets('the mark drawn on top answers, past or still ahead',
      (tester) async {
    // A plant, and a kill 100 ms later whose killer's portrait overlaps
    // the plant's circle.
    final playback = _match(2, ends: [
      ReplayRoundEnd.elimination
    ], kills: [
      {'timeMs': 5100, 'victim': 'b', 'killer': 'a'},
    ], first: {
      'plant': {'timeMs': 5000, 'site': 'A', 'subject': 'a'},
    });
    await _pumpDock(tester, playback);
    await tester.tap(find.byIcon(LucideIcons.pin));
    await tester.pump();
    final track = tester.getRect(find.byWidgetPredicate((widget) =>
        widget is CustomPaint &&
        widget.painter.runtimeType.toString() == '_ScrubberPainter'));
    // Inside both the plant's circle and the portrait's ring.
    final overlap = Offset(track.left + track.width * 0.5, track.top + 20);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    Future<ReplayEventKind> hovered(int timeMs) async {
      playback.seek(timeMs);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      await mouse.moveTo(overlap);
      await tester.pump();
      return tester
          .widget<ReplayEventLine>(find.byType(ReplayEventLine))
          .event
          .kind;
    }

    // Both still ahead, faded together: the plant's circle is on top.
    expect(await hovered(4000), ReplayEventKind.plant);
    // The plant passed, the kill ahead: the faded portrait is on top.
    expect(await hovered(5050), ReplayEventKind.kill);
    // Both passed: the plant's circle is on top again.
    expect(await hovered(6000), ReplayEventKind.plant);
  });

  group('resting on the playback row', () {
    Finder scrubber() => find.byWidgetPredicate((widget) =>
        widget is CustomPaint &&
        widget.painter.runtimeType.toString() == '_ScrubberPainter');
    bool storyOpen(WidgetTester tester) =>
        tester.getSize(scrubber()).height > 24;
    // Where the scrubber's line runs on screen.
    double line(WidgetTester tester) {
      final double y =
          (tester.widget<CustomPaint>(scrubber()).painter as dynamic).line;
      return tester.getRect(scrubber()).top + y;
    }

    Offset clock(WidgetTester tester) => tester.getCenter(find.text('0:04'));
    const away = Offset(10, 10);

    Future<TestGesture> pointer(WidgetTester tester) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: away);
      return mouse;
    }

    testWidgets('opens the story, its line barely moving', (tester) async {
      await _pumpDock(tester, _match(2)..seek(5000));
      final mouse = await pointer(tester);
      final rest = line(tester);
      await mouse.moveTo(clock(tester));
      await tester.pump(const Duration(milliseconds: 150));
      expect(storyOpen(tester), isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      expect(storyOpen(tester), isTrue);
      expect((line(tester) - rest).abs(), lessThan(8));

      // Leaving, it lingers a moment, then closes.
      await mouse.moveTo(away);
      await tester.pump(const Duration(milliseconds: 300));
      expect(storyOpen(tester), isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      expect(storyOpen(tester), isFalse);
      expect(line(tester), rest);
    });

    testWidgets('a quick pass opens nothing', (tester) async {
      await _pumpDock(tester, _match(2)..seek(5000));
      final mouse = await pointer(tester);
      await mouse.moveTo(clock(tester));
      await tester.pump(const Duration(milliseconds: 80));
      await mouse.moveTo(away);
      await tester.pump(const Duration(milliseconds: 600));
      expect(storyOpen(tester), isFalse);
    });

    testWidgets('a drag holds it open off the dock', (tester) async {
      final playback = _match(2)..seek(5000);
      await _pumpDock(tester, playback);
      final mouse = await pointer(tester);
      await mouse.moveTo(clock(tester));
      await tester.pump(const Duration(milliseconds: 250));
      expect(storyOpen(tester), isTrue);

      final track = tester.getRect(scrubber());
      await mouse.moveTo(Offset(track.left + 40, track.top + 27));
      await mouse.down(Offset(track.left + 40, track.top + 27));
      await mouse.moveBy(const Offset(30, 0));
      await mouse.moveBy(const Offset(30, -200));
      await tester.pump(const Duration(milliseconds: 800));
      expect(storyOpen(tester), isTrue);

      await mouse.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(storyOpen(tester), isFalse);
    });

    testWidgets('putting the pen away under a resting pointer opens it',
        (tester) async {
      final playback = _match(2)..seek(5000);
      final drawing = ReplayDrawing(playback);
      addTearDown(drawing.dispose);
      await _pumpDock(tester, playback, drawing: drawing);
      final mouse = await pointer(tester);
      await mouse.moveTo(clock(tester));
      await tester.pump(const Duration(milliseconds: 250));
      expect(storyOpen(tester), isTrue);

      drawing.start();
      await tester.pump();
      expect(storyOpen(tester), isFalse);
      drawing.stop();
      await tester.pump(const Duration(milliseconds: 250));
      expect(storyOpen(tester), isTrue);
    });

    testWidgets('never opens with the pen out', (tester) async {
      final playback = _match(2)..seek(5000);
      final drawing = ReplayDrawing(playback)..start();
      addTearDown(drawing.dispose);
      await _pumpDock(tester, playback, drawing: drawing);
      final mouse = await pointer(tester);
      await mouse.moveTo(clock(tester));
      await tester.pump(const Duration(milliseconds: 600));
      expect(storyOpen(tester), isFalse);
    });

    testWidgets('pinned, it stays open without the pointer', (tester) async {
      await _pumpDock(tester, _match(2)..seek(5000));
      final mouse = await pointer(tester);
      await mouse.moveTo(tester.getCenter(find.byIcon(LucideIcons.pin)));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byIcon(LucideIcons.pin));
      await tester.pump();
      await mouse.moveTo(away);
      await tester.pump(const Duration(milliseconds: 800));
      expect(storyOpen(tester), isTrue);

      // Unpinned, it closes once the pointer has gone.
      await mouse.moveTo(tester.getCenter(find.byIcon(LucideIcons.pin)));
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.pin));
      await mouse.moveTo(away);
      await tester.pump(const Duration(milliseconds: 800));
      expect(storyOpen(tester), isFalse);
    });
  });

  group('a lane of portraits', () {
    test('sits on its ticks when there is room', () {
      expect(replayStoryLane([20, 100, 200], 400, gap: 24, size: 22),
          [20, 100, 200]);
    });

    test('pushes close ones apart evenly about their moments', () {
      expect(replayStoryLane([100, 104, 108], 400, gap: 24, size: 22),
          [80, 104, 128]);
      // A run that would cross the end stays inside.
      expect(replayStoryLane([395, 398], 400, gap: 24, size: 22), [365, 389]);
    });

    test('closes up evenly when more than fit', () {
      final centres =
          replayStoryLane(List.filled(5, 50.0), 100, gap: 24, size: 20);
      expect(centres.first, 10);
      expect(centres.last, 90);
    });
  });
}
