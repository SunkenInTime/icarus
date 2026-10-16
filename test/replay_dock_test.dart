import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/replay/replay_document.dart';
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
/// even ones.
ReplayPlayback _match(
  int count, {
  List<ReplayRoundEnd> ends = ReplayRoundEnd.values,
  List<Map<String, Object?>> kills = const [],
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

Future<void> _pumpDock(WidgetTester tester, ReplayPlayback playback) async {
  await tester.binding.setSurfaceSize(const Size(1400, 600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      child: ShadApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ReplayDock(playback: playback),
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

    for (final end in ReplayRoundEnd.values) {
      expect(_asset(replayRoundEndAsset(end)), findsOneWidget, reason: '$end');
    }

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

    await tester.tap(find.byIcon(LucideIcons.chevronsUpDown));
    await tester.pump();
    final track = tester.getRect(find.byWidgetPredicate((widget) =>
        widget is CustomPaint &&
        widget.painter.runtimeType.toString() == '_ScrubberPainter'));
    expect(track.height, 64);
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

    await tester.tap(find.byIcon(LucideIcons.chevronsDownUp));
    await tester.pump();
    expect(portrait('Jett'), findsNothing);
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
