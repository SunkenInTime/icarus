// The verification driver: plays a JSON script against the running app, the
// way a user would use it, and checks what a user would notice after every
// step. Compiled in only with --dart-define=ICARUS_DRIVE=true; run it with
// tool/drive/run.ps1, which says how.
//
// Every run checks, without the script asking:
// - Flutter errors the app reports, including a canvas whose coordinates
//   something replaced (CanvasCoordinates checks after every frame in
//   driver builds).
// - Agents and lineup ends drawn somewhere other than where their saved
//   positions put them (misplacedItems), after every step and through every
//   soak. Agents with a view cone or circle aren't checked yet.
// - Cloud work that never settles, in waitSettled.
// - Steps that fail.
// The log ends with a SUMMARY line saying CLEAN or PROBLEMS; tool/drive/
// run.ps1 reads it, since the app's exit code can't be trusted.
//
// A step is one JSON object; the key that names it comes first. In any
// string, "{run}" becomes this run's id (ICARUS_DRIVE_RUN), so names and
// item ids are new each run: the server refuses an id it already holds.
// "{out}" becomes the run's output folder and "{here}" the script's own.
// A step with "optional": true that fails is logged and not counted.
//
// Waiting and checking
//   {"wait": s}                        sleep s seconds
//   {"soak": s}                        sleep s seconds, checking items every 250 ms
//   {"waitText": t, "gone": b?, "seconds": n?}
//   {"waitSettled": s}                 cloud queue and uploads empty, synced
//   {"waitFile": path, "seconds": n?}
//   {"signal": name} / {"waitSignal": name, "seconds": n?}
//                                      between two instances (ICARUS_DRIVE_SIGNALS)
// Input, the way a mouse and keyboard deliver it
//   {"tapText": t, "nth": n?, "button": "secondary"?}
//   {"tapKey": valueKey, "nth": n?}    {"tapIcon": name, "nth": n?}
//   {"tapAt": [x, y]}                  {"hoverAt": [x, y]}
//   {"dragAt": [x1, y1, x2, y2]}       {"path": [[x, y], ...]}
//   {"scrollAt": [x, y, dy]}           {"key": name}  {"keyCombo": [names]}
//   {"resize": [w, h]}                 the window
// Editor content
//   {"addAgent": id, "at": [x, y], "agent": "jett"?}
//   {"addSmoke": id, "at": [x, y]}     {"addText": id, "at": [x, y], "text": t?}
//   {"addImage": path, "at": [x, y]}   {"addLineup": n}  two lineups, ids lo1{n}, lo2{n}
//   {"dragAgent": id, "by": [dx, dy]}  {"hoverAgent": id}
// Library and cloud
//   {"signIn": true}                   ICARUS_DRIVE_EMAIL / ICARUS_DRIVE_PASSWORD
//   {"newLocal": map, "name": n}       {"newCloud": name, "map": m?}
//   {"newCloudFolder": name}           {"openCloudFolder": name}
//   {"importReplay": path}             {"fakeSaveDir": dir}  answers save dialogs
// Recording
//   {"shot": png}                      {"burst": prefix, "count": n?, "every": ms?}
//   {"logCoords": tag}                 {"logPage": tag}  {"probe": tag}  {"texts": 1}
//   {"exit": 1}
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/dev/drive/drive_checks.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/cloud_sync_status_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;
import 'package:window_manager/window_manager.dart';

/// Starts the script in ICARUS_DRIVE_SCRIPT, if there is one, once the app
/// is up. Call it after runApp.
void startDrive() {
  final env = Platform.environment;
  final script = env['ICARUS_DRIVE_SCRIPT'];
  if (script == null) return;
  _logPath = env['ICARUS_DRIVE_LOG'];
  _runId = env['ICARUS_DRIVE_RUN'] ??
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  _signals = env['ICARUS_DRIVE_SIGNALS'];
  _out = env['ICARUS_DRIVE_OUT'] ?? File(script).parent.path;
  _here = File(script).parent.path;
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    _flutterErrors++;
    _log(
      'FLUTTER-ERROR ${_describe(details.exception)} '
      '@ ${_lines('${details.stack ?? ''}', 8, ' | ')}',
    );
    previous?.call(details);
  };
  unawaited(_play(script));
}

String? _logPath;
String _runId = '';
String? _signals;
String _out = '.';
String _here = '.';
final _entries = <String>[];
var _flutterErrors = 0;
var _failedSteps = 0;
var _steps = 0;
final _misplaced = <String>{};

void _log(String line) =>
    _entries.add('${DateTime.now().toIso8601String().substring(11, 23)} $line');

Future<void> _flush() async {
  final path = _logPath;
  if (path != null) await File(path).writeAsString('${_entries.join('\n')}\n');
}

/// What went wrong, in full: a release build's FlutterError prints only its
/// first line.
String _describe(Object error) {
  if (error is! FlutterError) return _lines('$error', 3, ' / ');
  return [
    for (final node in error.diagnostics)
      if (node.value case final List<Object> parts) parts.join() else '$node'
  ].join(' / ');
}

String _lines(String text, int count, String joiner) =>
    text.split('\n').take(count).join(joiner);

Future<void> _play(String script) async {
  // The app opens its window and first screen meanwhile.
  await Future<void>.delayed(const Duration(seconds: 6));
  final List<Object?> steps;
  try {
    steps = jsonDecode(await File(script).readAsString()) as List;
  } catch (error) {
    _log('FAIL reading $script: $error');
    _log('SUMMARY steps=0 failed=1 flutterErrors=0 misplaced=0 PROBLEMS');
    await _flush();
    exit(0);
  }
  _log('RUN $_runId $script');
  for (final raw in steps) {
    if (raw is! Map<String, dynamic> || raw.isEmpty) {
      _failedSteps++;
      _log('FAIL not a step: ${jsonEncode(raw)}');
      continue;
    }
    final step = _expand(raw) as Map<String, dynamic>;
    if (step['exit'] != null) break;
    final started = DateTime.now();
    _steps++;
    try {
      await _run(step);
      _log(
        'ok ${jsonEncode(step)} '
        '(${DateTime.now().difference(started).inMilliseconds} ms)',
      );
    } catch (error, stack) {
      if (step['optional'] == true) {
        _log('SKIP ${jsonEncode(step)}: $error');
      } else {
        _failedSteps++;
        _log(
            'FAIL ${jsonEncode(step)}: $error @ ${_lines('$stack', 8, ' | ')}');
      }
    }
    try {
      await _checkItems();
    } catch (error) {
      _failedSteps++;
      _log('FAIL checking items: $error');
    }
    await _flush();
  }
  final problems = _flutterErrors + _failedSteps + _misplaced.length;
  _log(
    'SUMMARY steps=$_steps failed=$_failedSteps '
    'flutterErrors=$_flutterErrors misplaced=${_misplaced.length} '
    '${problems == 0 ? 'CLEAN' : 'PROBLEMS'}',
  );
  await _flush();
  if (steps.any((step) => step is Map && step['exit'] != null)) exit(0);
}

Object? _expand(Object? value) => switch (value) {
      String() => value
          .replaceAll('{run}', _runId)
          .replaceAll('{out}', _out)
          .replaceAll('{here}', _here),
      List() => [for (final item in value) _expand(item)],
      Map() => {
          for (final entry in value.entries)
            entry.key as String: _expand(entry.value),
        },
      _ => value,
    };

/// Logs items drawn away from their saved positions. An item counts when it
/// is still misplaced a moment later: a resize rebuilds the canvas a frame
/// after it lays out.
Future<void> _checkItems() async {
  await _frames();
  if (misplacedItems(appProviderContainer).isEmpty) return;
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _frames();
  for (final line in misplacedItems(appProviderContainer)) {
    if (_misplaced.add(line)) _log('MISPLACED $line');
  }
}

Future<void> _frames([int count = 3]) async {
  for (var i = 0; i < count; i++) {
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
  }
}

Future<void> _waitFor(bool Function() condition, num seconds) async {
  final deadline = DateTime.now().add(
    Duration(milliseconds: (seconds * 1000).round()),
  );
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('waited $seconds s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> _seconds(num seconds) =>
    Future<void>.delayed(Duration(milliseconds: (seconds * 1000).round()));

Offset _point(Map<String, dynamic> step, String key, [int at = 0]) {
  final xy = (step[key] as List).cast<num>();
  return Offset(xy[at].toDouble(), xy[at + 1].toDouble());
}

// Finding things on screen.

bool _isText(Widget widget, String text) =>
    (widget is Text &&
        (widget.data ?? widget.textSpan?.toPlainText()) == text) ||
    (widget is RichText && widget.text.toPlainText() == text);

bool _hasKey(Widget widget, String key) => widget.key == ValueKey<String>(key);

/// The middle of the [nth] widget passing [test] that is laid out, in the
/// order the tree holds them: a screen under another comes first.
Offset _centerOf(bool Function(Widget) test, {int nth = 0}) {
  final found = <Offset>[];
  void visit(Element element) {
    if (test(element.widget)) {
      final box = element.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) {
        found.add(box.localToGlobal(box.size.center(Offset.zero)));
      }
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  if (found.length <= nth) throw StateError('found ${found.length}');
  return found[nth];
}

/// The middle of item [id] as drawn: its innermost outline.
Offset _itemCenter(String id) {
  RenderEditorItemOutline? best;
  var bestDepth = -1;
  void walk(RenderObject node, int depth) {
    if (node is RenderEditorItemOutline && depth > bestDepth) {
      best = node;
      bestDepth = depth;
    }
    node.visitChildren((child) => walk(child, depth + 1));
  }

  void visit(Element element) {
    if (element.widget.key == ValueKey('entity-$id')) {
      final box = element.findRenderObject();
      if (box != null) walk(box, 0);
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  final outline = best;
  if (outline == null) throw StateError('no outline for $id');
  return outline.localToGlobal(outline.size.center(Offset.zero));
}

// The mouse.

var _pointer = 900;
Offset? _mouseAt;

/// Puts the mouse at [at]. MouseTracker asserts in debug builds when the
/// same device is added twice, so the mouse leaves first.
void _addMouse(int pointer, Offset at) {
  final binding = GestureBinding.instance;
  final previous = _mouseAt;
  if (previous != null) {
    binding.handlePointerEvent(
      PointerRemovedEvent(kind: PointerDeviceKind.mouse, position: previous),
    );
  }
  _mouseAt = at;
  binding.handlePointerEvent(
    PointerAddedEvent(
      pointer: pointer,
      kind: PointerDeviceKind.mouse,
      position: at,
    ),
  );
}

Future<void> _hover(Offset at) async {
  final pointer = _pointer++;
  _addMouse(pointer, at);
  GestureBinding.instance.handlePointerEvent(
    PointerHoverEvent(
      pointer: pointer,
      kind: PointerDeviceKind.mouse,
      position: at,
    ),
  );
  await _frames();
}

Future<void> _tap(Offset at, {bool secondary = false}) async {
  final pointer = _pointer++;
  final binding = GestureBinding.instance;
  _addMouse(pointer, at);
  binding.handlePointerEvent(
    PointerHoverEvent(
      pointer: pointer,
      kind: PointerDeviceKind.mouse,
      position: at,
    ),
  );
  await _frames(2);
  binding.handlePointerEvent(
    PointerDownEvent(
      pointer: pointer,
      kind: PointerDeviceKind.mouse,
      buttons: secondary ? kSecondaryMouseButton : kPrimaryMouseButton,
      position: at,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 60));
  binding.handlePointerEvent(
    PointerUpEvent(
      pointer: pointer,
      kind: PointerDeviceKind.mouse,
      position: at,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await _frames();
}

/// Presses at the first point, moves through the rest, and lets go.
Future<void> _drag(List<Offset> points, {int stepsPerLeg = 30}) async {
  final pointer = _pointer++;
  final binding = GestureBinding.instance;
  _addMouse(pointer, points.first);
  binding.handlePointerEvent(
    PointerHoverEvent(
      pointer: pointer,
      kind: PointerDeviceKind.mouse,
      position: points.first,
    ),
  );
  await _frames(2);
  binding.handlePointerEvent(
    PointerDownEvent(
      pointer: pointer,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
      position: points.first,
    ),
  );
  await _frames(2);
  var last = points.first;
  for (final to in points.skip(1)) {
    final from = last;
    for (var i = 1; i <= stepsPerLeg; i++) {
      final at = from + (to - from) * (i / stepsPerLeg);
      binding.handlePointerEvent(
        PointerMoveEvent(
          pointer: pointer,
          kind: PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
          position: at,
          delta: at - last,
        ),
      );
      last = at;
      await _frames(1);
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  binding.handlePointerEvent(
    PointerUpEvent(
      pointer: pointer,
      kind: PointerDeviceKind.mouse,
      position: last,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _frames();
}

// The keyboard.

const _keys = {
  'digit0': (LogicalKeyboardKey.digit0, PhysicalKeyboardKey.digit0, '0'),
  'digit1': (LogicalKeyboardKey.digit1, PhysicalKeyboardKey.digit1, '1'),
  'digit2': (LogicalKeyboardKey.digit2, PhysicalKeyboardKey.digit2, '2'),
  'digit3': (LogicalKeyboardKey.digit3, PhysicalKeyboardKey.digit3, '3'),
  'keyA': (LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA, 'a'),
  'keyC': (LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC, 'c'),
  'keyQ': (LogicalKeyboardKey.keyQ, PhysicalKeyboardKey.keyQ, 'q'),
  'keyS': (LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS, 's'),
  'keyV': (LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV, 'v'),
  'keyZ': (LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ, 'z'),
  'controlLeft': (
    LogicalKeyboardKey.controlLeft,
    PhysicalKeyboardKey.controlLeft,
    null,
  ),
  'shiftLeft': (
    LogicalKeyboardKey.shiftLeft,
    PhysicalKeyboardKey.shiftLeft,
    null,
  ),
  'space': (LogicalKeyboardKey.space, PhysicalKeyboardKey.space, ' '),
  'escape': (LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape, null),
  'delete': (LogicalKeyboardKey.delete, PhysicalKeyboardKey.delete, null),
  'arrowLeft': (
    LogicalKeyboardKey.arrowLeft,
    PhysicalKeyboardKey.arrowLeft,
    null,
  ),
  'arrowRight': (
    LogicalKeyboardKey.arrowRight,
    PhysicalKeyboardKey.arrowRight,
    null,
  ),
};

var _keyTime = 0;

/// Presses [names] in order and lets go in reverse, as hands do.
void _press(List<String> names) {
  final events = <KeyEvent>[
    for (final name in names)
      KeyDownEvent(
        physicalKey: _keys[name]!.$2,
        logicalKey: _keys[name]!.$1,
        character: _keys[name]!.$3,
        timeStamp: Duration(milliseconds: _keyTime += 20),
      ),
    for (final name in names.reversed)
      KeyUpEvent(
        physicalKey: _keys[name]!.$2,
        logicalKey: _keys[name]!.$1,
        timeStamp: Duration(milliseconds: _keyTime += 20),
      ),
  ];
  for (final event in events) {
    HardwareKeyboard.instance.handleKeyEvent(event);
    // The app's shortcuts still listen here; the engine sends both.
    // ignore: deprecated_member_use
    ServicesBinding.instance.keyEventManager.keyMessageHandler?.call(
      // ignore: deprecated_member_use
      KeyMessage([event], null),
    );
  }
}

const _icons = {
  'x': LucideIcons.x,
  'house300': LucideIcons.house300,
  'chevronLeft300': LucideIcons.chevronLeft300,
  'pencil': LucideIcons.pencil,
  'camera': LucideIcons.camera,
  'play': LucideIcons.play,
  'pause': LucideIcons.pause,
};

// Stands in for the OS save dialog: answers with dir/fileName and writes the
// bytes when given, as FilePicker does on desktop.
class _FakeSaver extends FilePicker {
  _FakeSaver(this.dir);
  final String dir;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    await Directory(dir).create(recursive: true);
    final path = '$dir${Platform.pathSeparator}$fileName';
    if (bytes != null) await File(path).writeAsBytes(bytes);
    _log('SAVE $path bytes=${bytes?.length}');
    return path;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    await Directory(dir).create(recursive: true);
    return dir;
  }
}

// Cloud state.

bool _settled() {
  final c = appProviderContainer;
  return c.read(strategyOpQueueProvider).pending.isEmpty &&
      c.read(cloudMediaUploadQueueProvider).jobs.isEmpty &&
      c.read(cloudSyncStatusProvider) == CloudSyncStatus.synced;
}

String _probe() {
  final c = appProviderContainer;
  final snapshot = c.read(remoteEditorSnapshotProvider).valueOrNull;
  final queue = c.read(strategyOpQueueProvider);
  return jsonEncode({
    'strategy': c.read(strategyProvider).strategyName,
    'remoteElements':
        snapshot?.activePage?.elements.where((e) => !e.deleted).length,
    'remoteLineups':
        snapshot?.activePage?.lineups.where((e) => !e.deleted).length,
    'queuedOps': queue.pending.length,
    'attention': queue.attentionByEntityKey.length,
    'queueError': '${queue.lastError}',
    'mediaJobs': [
      for (final job in c.read(cloudMediaUploadQueueProvider).jobs)
        '${job.assetPublicId}:${job.state.name}',
    ],
    'syncStatus': c.read(cloudSyncStatusProvider).name,
  });
}

/// Puts a just-added item, which starts at (500, 500), so that its middle is
/// drawn at [target] on screen.
Future<void> _place(
  String id,
  Offset target,
  void Function(Offset) moveTo,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _frames();
  final at = _itemCenter(id);
  final coordinates = CoordinateSystem.instance;
  final zoom = appProviderContainer.read(screenZoomProvider);
  final onScreen = (coordinates.screenToCoordinate(target) -
          coordinates.screenToCoordinate(at)) /
      zoom;
  // Defense draws the attack-side world turned half a circle.
  final delta =
      appProviderContainer.read(mapProvider).isAttack ? onScreen : -onScreen;
  moveTo(const Offset(500, 500) + delta);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _frames();
}

File _signal(String name) {
  final dir = _signals;
  if (dir == null) throw StateError('ICARUS_DRIVE_SIGNALS is not set');
  return File('$dir${Platform.pathSeparator}$name');
}

Future<void> _run(Map<String, dynamic> step) async {
  final c = appProviderContainer;
  final name = step.keys.first;
  final value = step[name];
  final nth = (step['nth'] ?? 0) as int;
  switch (name) {
    case 'wait':
      await _seconds(value as num);
    case 'soak':
      final until = DateTime.now().add(
        Duration(milliseconds: ((value as num) * 1000).round()),
      );
      while (DateTime.now().isBefore(until)) {
        await _checkItems();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    case 'waitText':
      final gone = step['gone'] == true;
      await _waitFor(() {
        try {
          _centerOf((w) => _isText(w, value as String));
          return !gone;
        } on StateError {
          return gone;
        }
      }, (step['seconds'] ?? 120) as num);
    case 'waitSettled':
      // Work that never reaches the server is a failure, whatever else
      // went right.
      try {
        await _waitFor(_settled, value as num);
      } on TimeoutException {
        throw StateError('not settled: ${_probe()}');
      }
    case 'waitFile':
      final file = File(value as String);
      await _waitFor(file.existsSync, (step['seconds'] ?? 300) as num);
    case 'signal':
      await _signal(value as String).writeAsString(_runId);
    case 'waitSignal':
      // Only this run's: a signal file left from another run doesn't count.
      final file = _signal(value as String);
      await _waitFor(
        () => file.existsSync() && file.readAsStringSync() == _runId,
        (step['seconds'] ?? 300) as num,
      );
    case 'tapText':
      await _tap(
        _centerOf((w) => _isText(w, value as String), nth: nth),
        secondary: step['button'] == 'secondary',
      );
    case 'tapKey':
      await _tap(
        _centerOf((w) => _hasKey(w, value as String), nth: nth),
        secondary: step['button'] == 'secondary',
      );
    case 'tapIcon':
      final icon = _icons[value as String]!;
      await _tap(_centerOf((w) => w is Icon && w.icon == icon, nth: nth));
    case 'tapAt':
      await _tap(_point(step, name), secondary: step['button'] == 'secondary');
    case 'hoverAt':
      await _hover(_point(step, name));
    case 'dragAt':
      await _drag([_point(step, name), _point(step, name, 2)]);
    case 'path':
      await _drag([
        for (final p in (value as List).cast<List>())
          Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
      ], stepsPerLeg: 6);
    case 'scrollAt':
      final xy = (value as List).cast<num>();
      GestureBinding.instance.handlePointerEvent(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: Offset(xy[0].toDouble(), xy[1].toDouble()),
          scrollDelta: Offset(0, xy[2].toDouble()),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _frames();
    case 'key':
      _press([value as String]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _frames();
    case 'keyCombo':
      _press((value as List).cast<String>());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _frames();
    case 'resize':
      final wh = (value as List).cast<num>();
      await windowManager.setSize(Size(wh[0].toDouble(), wh[1].toDouble()));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _frames();
    case 'addAgent':
      final id = value as String;
      final agents = c.read(agentProvider.notifier);
      agents.addAgent(
        PlacedAgent(
          id: id,
          type: AgentType.values.byName((step['agent'] ?? 'jett') as String),
          position: const Offset(500, 500),
          isAlly: true,
        ),
      );
      await _place(id, _point(step, 'at'), (p) => agents.updatePosition(p, id));
    case 'addSmoke':
      final id = value as String;
      final abilities = c.read(abilityProvider.notifier);
      abilities.addAbility(
        PlacedAbility(
          data: AgentData.agents[AgentType.brimstone]!.abilities[2],
          position: const Offset(500, 500),
          id: id,
          isAlly: true,
        ),
      );
      await _place(
        id,
        _point(step, 'at'),
        (p) => abilities.updatePosition(p, id),
      );
    case 'addText':
      final id = value as String;
      final texts = c.read(textProvider.notifier);
      texts.addText(
        PlacedText(
          id: id,
          position: const Offset(500, 500),
          sizeVersion: worldSizedMediaVersion,
        )..text = (step['text'] ?? 'B site') as String,
      );
      await _place(id, _point(step, 'at'), (p) => texts.updatePosition(p, id));
    case 'addImage':
      final strategy = c.read(strategyProvider);
      final images = c.read(placedImageProvider.notifier);
      await images.addImage(
        imageBytes: await File(value as String).readAsBytes(),
        strategyId: strategy.strategyId,
        strategySource: strategy.source,
        fileExtension: '.png',
        position: const Offset(500, 500),
      );
      final id = c.read(placedImageProvider).images.last.id;
      await _place(id, _point(step, 'at'), (p) => images.updatePosition(p, id));
    case 'addLineup':
      final smoke = AgentData.agents[AgentType.brimstone]!.abilities[2];
      LineUpGraph one(String n, Offset from, Offset to) => LineUpGraph(
            origins: [
              LineUpOrigin(
                id: 'lo$n',
                agent: PlacedAgent(
                  id: 'lo$n',
                  type: AgentType.brimstone,
                  position: from,
                  isAlly: true,
                  lineUpID: 'lo$n',
                ),
              ),
            ],
            landings: [
              LineUpLanding(
                id: 'll$n',
                ability: PlacedAbility(
                  id: 'll$n',
                  data: smoke,
                  position: to,
                  isAlly: true,
                  lineUpID: 'll$n',
                ),
              ),
            ],
            links: [
              LineUpLink(
                id: 'lk$n',
                originId: 'lo$n',
                landingId: 'll$n',
                name: 'Smoke $n',
                images: const [],
              ),
            ],
          );
      final lineUps = c.read(lineUpProvider.notifier);
      lineUps.addRecovered(
        one('1$value', const Offset(650, 700), const Offset(760, 560)),
      );
      lineUps.addRecovered(
        one('2$value', const Offset(1050, 760), const Offset(820, 330)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _frames();
    case 'dragAgent':
      final from = _itemCenter(value as String);
      await _drag([from, from + _point(step, 'by')]);
    case 'hoverAgent':
      final id = value as String;
      await _hover(
        _centerOf((w) => w is AgentWidget && (w.id == id || w.lineUpId == id)),
      );
    case 'signIn':
      final email = Platform.environment['ICARUS_DRIVE_EMAIL']!;
      final signedIn = Supabase.instance.client.auth.currentUser?.email;
      if (signedIn != null && signedIn != email) {
        throw StateError('signed in as $signedIn, not $email');
      }
      if (signedIn == null) {
        final error =
            await c.read(authProvider.notifier).signInWithEmailPassword(
                  email: email,
                  password: Platform.environment['ICARUS_DRIVE_PASSWORD']!,
                );
        if (error != null) throw StateError(error);
      }
      await _waitFor(() => c.read(authProvider).isConvexUserReady, 60);
    case 'newLocal':
      await c.read(strategyProvider.notifier).createNewStrategy(
            map: MapValue.values.byName(value as String),
            name: step['name'] as String,
            local: true,
          );
    case 'newCloud':
      await c.read(strategyProvider.notifier).createNewStrategy(
            map: MapValue.values.byName((step['map'] ?? 'ascent') as String),
            name: value as String,
          );
    case 'newCloudFolder':
      final id = 'drive-${DateTime.now().microsecondsSinceEpoch}';
      await c
          .read(convexStrategyRepositoryProvider)
          .createFolder(publicId: id, name: value as String);
    case 'openCloudFolder':
      await _waitFor(
        () => (c.read(cloudFolderTreeProvider).valueOrNull ?? const []).any(
          (entry) => entry.folder.name == value,
        ),
        30,
      );
      final folder = c
          .read(cloudFolderTreeProvider)
          .value!
          .firstWhere((entry) => entry.folder.name == value)
          .folder;
      c
          .read(folderProvider.notifier)
          .openFolder(folderId: folder.id, store: LibraryWorkspace.cloud);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _frames();
    case 'importReplay':
      await c.read(replayLibraryProvider.notifier).import(value as String);
    case 'fakeSaveDir':
      FilePicker.platform = _FakeSaver(value as String);
    case 'shot':
      await _frames();
      final view = RendererBinding.instance.renderViews.first;
      final layer =
          // The root layer is what the window shows.
          // ignore: invalid_use_of_protected_member
          view.debugLayer as OffsetLayer? ?? (view.layer as OffsetLayer);
      final image = await layer.toImage(
        Offset.zero & (view.size * view.flutterView.devicePixelRatio),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(value as String).writeAsBytes(bytes!.buffer.asUint8List());
    case 'burst':
      for (var i = 0; i < ((step['count'] ?? 10) as int); i++) {
        await _run({'shot': '$value-${i.toString().padLeft(3, '0')}.png'});
        await Future<void>.delayed(
          Duration(milliseconds: (step['every'] ?? 100) as int),
        );
      }
    case 'logCoords':
      final canvas = _canvasSize();
      _log(
        'COORDS $value canvas=${_size(canvas)} '
        'coordinates=${_size(CoordinateSystem.instance.playAreaSize)} '
        'agents=${[
          for (final a in c.read(agentProvider))
            '${a.id}@(${a.position.dx.toStringAsFixed(1)}, '
                '${a.position.dy.toStringAsFixed(1)})'
        ]}',
      );
    case 'logPage':
      _log(
        'PAGE $value strategy=${c.read(strategyProvider).strategyName} '
        'agents=${c.read(agentProvider).length} '
        'abilities=${c.read(abilityProvider).length} '
        'texts=${c.read(textProvider).length} '
        'drawings=${c.read(drawingProvider).elements.length} '
        'images=${c.read(placedImageProvider).images.length} '
        'lineups=${c.read(lineUpProvider).graph.links.length}',
      );
    case 'probe':
      _log('PROBE $value ${_probe()}');
    case 'texts':
      final seen = <String>[];
      void visit(Element element) {
        final widget = element.widget;
        if (widget is Text) {
          seen.add(widget.data ?? widget.textSpan?.toPlainText() ?? '');
        }
        element.visitChildElements(visit);
      }
      WidgetsBinding.instance.rootElement?.visitChildElements(visit);
      _log('TEXTS ${jsonEncode(seen)}');
    default:
      throw ArgumentError('no step called $name');
  }
}

Size? _canvasSize() {
  Size? size;
  void visit(Element element) {
    if (element.widget is InteractiveMap) {
      final box = element.findRenderObject();
      if (box is RenderBox && box.hasSize) size = box.size;
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return size;
}

String _size(Size? size) => size == null
    ? 'none'
    : '${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}';
