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
//   {"tapAt": [x, y], "hold": s?}      {"hoverAt": [x, y]}
//   {"tapDoor": id}  {"hoverDoor": id}  the middle of a map door's bar
//                                      hold: seconds down, for a long press
//   {"dragAt": [x1, y1, x2, y2]}       {"path": [[x, y], ...], "held": png?}
//                                      held: a shot before letting go
//   {"scrollAt": [x, y, dy]}           {"key": name}  {"keyCombo": [names]}
//   {"holdKey": name}  {"letGoKey": name}  a key held across other steps
//   {"resize": [w, h]}                 the window
//   {"typeText": t}                    replaces the text in the last text field
// Editor content
//   {"addAgent": id, "at": [x, y], "agent": "jett"?}
//   {"addHighTide": id, "at": [x, y], "wall": [[dx, dy], ...]?}
//   {"addSmoke": id, "at": [x, y]}     {"addText": id, "at": [x, y], "text": t?}
//   {"setCaption": id, "text": t}      what the caption dialog's Done does
//   {"addUtility": id, "type": name, "at": [x, y], "door": id?}  spike, customRectangle, customCircle
//   {"addImage": path, "at": [x, y]}   {"addLineup": n, "legacy": b?}  two lineups, ids
//                                      lo1{n}, lo2{n}; legacy ones share one id per lineup
//   {"addAbility": id, "agent": name, "slot": n, "at": [x, y]}
//   {"dragAgent": id, "by": [dx, dy]}  {"hoverAgent": id}
//   {"dragAgent": id, "toWorld": [x, y]}
//                                      drops the middle of any placed item at this
//                                      point of the canvas as drawn, 1778 by 1000;
//                                      the id lastImage is the newest picture
// Library and cloud
//   {"signIn": true}                   ICARUS_DRIVE_EMAIL / ICARUS_DRIVE_PASSWORD
//   {"newLocal": map, "name": n}       {"newCloud": name, "map": m?}
//   {"newCloudFolder": name}           {"openCloudFolder": name}
//   {"shareLink": role, "file": path}  makes a link to the open strategy and
//                                      writes its code to the file
//   {"openShareLink": path}            opens the link whose code is in the file
//   {"importReplay": path}             {"fakeSaveDir": dir, "as": name?}
//                                      answers save dialogs, typing name if given
//   {"fakePick": path}                 answers open dialogs with this file
//   {"dropFiles": [paths], "at": [x, y]}  dropped from Explorer
//   {"exportIca": path}                {"importIca": path}
// Pictures
//   {"expectPicturesIn": dir}          fails unless the open strategy's pictures
//                                      are in a folder under dir
//   {"clipboard": path, "file": b?}    puts a bitmap on the Windows clipboard as
//                                      a screenshot does; with file, copies the
//                                      file as Explorer does
//   {"openLineup": linkId}             the lineup's media dialog
//   {"mark": name}                     starts a clock
//   {"watchPicture": name, "gone": t?} logs the time since mark name when a
//                                      pasted picture is first drawn, once text
//                                      t has left the screen; runs behind the
//                                      next steps
//   {"watchFrames": true}  {"watchFrames": false, "tag": t}
//                                      keeps frames coming, then logs the worst
//                                      gap between two of them
// Recording
//   {"shot": png}                      {"burst": prefix, "count": n?, "every": ms?}
//   {"logWalls": tag}                  every ability's position and wall path
//   {"logUtilities": tag}              every utility's type, position and door
//   {"logDoors": tag}                  the map doors changed on the page
//   {"logCoords": tag}                 {"logPage": tag}  {"probe": tag}  {"texts": 1}
//   {"logCaptions": tag}               every placed item's caption
//   {"logCard": tag}                   the caption card that's open, and where
//   {"logLineups": tag}                {"logImages": tag}
//   {"framesStart": 1} / {"framesLog": tag}   frame build and raster times between
//                                      them: p50, p90, p99, worst, in ms
//   {"expectText": t, "count": n}      fails unless t is on screen n times
//   {"expectSelected": n}              fails unless n items are selected
//   {"expectAgents": n}                fails unless n agents are on the page
//   {"expectInView": n, "only": id?}   fails unless n items are drawn, all of
//                                      them in the map's view; logs their outlines.
//                                      With only, checks that item, and the page
//                                      can have more
//   {"expectDead": n}                  fails unless n agents on the page are dead
//   {"expectItem": id, "gone": b?}     fails unless the item is on the page, or
//                                      with gone, unless it is not
//   {"expectImages": n, "lineups": m?} fails unless n pictures are on the page,
//                                      and m in its lineups
//   {"exit": 1}
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show showDialog;
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
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/dev/drive/drive_checks.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/cloud_sync_status_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/widgets/map_door_layer.dart';
import 'package:icarus/widgets/draggable_widgets/caption_menu.dart';
import 'package:icarus/widgets/canvas_selection_layer.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/share/share_link_format.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:path/path.dart' as path;
import 'package:shadcn_ui/shadcn_ui.dart';
// The driver alone swaps the platform's launcher; the app uses url_launcher.
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;
import 'package:window_manager/window_manager.dart';

/// Starts the script in ICARUS_DRIVE_SCRIPT, if there is one, once the app
/// is up. Call it after runApp.
void startDrive() {
  final env = Platform.environment;
  final script = env['ICARUS_DRIVE_SCRIPT'];
  if (script == null) return;
  _ignoreOsFocus();
  UrlLauncherPlatform.instance = _RecordingUrlLauncher();
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
final _frameTimings = <ui.FrameTiming>[];

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
  await Future.wait(_pictureWatches);
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

/// How many widgets passing [test] are laid out.
int _countOf(bool Function(Widget) test) {
  var count = 0;
  void visit(Element element) {
    if (test(element.widget)) {
      final box = element.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) count++;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildElements(visit);
  return count;
}

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

/// The middle of a map door's bar, on the screen.
Offset _doorPoint(String id) {
  final door = mapDoors.firstWhere((door) => door.id == id);
  // The bar's layer fills the canvas, so its middle is the canvas's.
  final canvasMiddle = _centerOf((w) => _hasKey(w, 'map-door-$id'));
  final canvas = CoordinateSystem.instance.effectiveSize;
  final onCanvas = mapDoorMiddleOnCanvas(
    door,
    isAttack: appProviderContainer.read(mapProvider).isAttack,
  );
  return canvasMiddle - canvas.center(Offset.zero) + onCanvas;
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

Future<void> _tap(
  Offset at, {
  bool secondary = false,
  Duration hold = const Duration(milliseconds: 60),
}) async {
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
  await Future<void>.delayed(hold);
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
Future<void> _drag(
  List<Offset> points, {
  int stepsPerLeg = 30,
  String? shotWhileHeld,
}) async {
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
  if (shotWhileHeld != null) await _run({'shot': shotWhileHeld});
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
  'keyE': (LogicalKeyboardKey.keyE, PhysicalKeyboardKey.keyE, 'e'),
  'keyF': (LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF, 'f'),
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
  'altLeft': (
    LogicalKeyboardKey.altLeft,
    PhysicalKeyboardKey.altLeft,
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
/// Keeps other windows from changing what the script is testing. When one
/// takes the foreground, Flutter parks keyboard focus at the root of the focus
/// tree: a text field blurs and a driver key reaches no widget. On a desktop
/// shared with other driver runs that happens all the time, so a driver run
/// ignores OS focus. It needs none: its input is sent inside the process.
void _ignoreOsFocus() {
  final binding = WidgetsBinding.instance;
  binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  binding.platformDispatcher.onViewFocusChange = (_) {};
  SystemChannels.lifecycle.setMessageHandler((_) async => null);
}

/// Fails a key step that would reach no widget, instead of logging ok.
Future<void> _expectKeyFocus() async {
  try {
    await _waitFor(
      () => FocusManager.instance.primaryFocus?.context != null,
      2,
    );
  } on TimeoutException {
    throw StateError(
      'no keyboard focus for this key: ${FocusManager.instance.primaryFocus}',
    );
  }
}

void _press(List<String> names) {
  _sendKeys([
    for (final name in names) _keyDown(name),
    for (final name in names.reversed) _keyUp(name),
  ]);
}

KeyEvent _keyDown(String name) => KeyDownEvent(
      physicalKey: _keys[name]!.$2,
      logicalKey: _keys[name]!.$1,
      character: _keys[name]!.$3,
      timeStamp: Duration(milliseconds: _keyTime += 20),
    );

KeyEvent _keyUp(String name) => KeyUpEvent(
      physicalKey: _keys[name]!.$2,
      logicalKey: _keys[name]!.$1,
      timeStamp: Duration(milliseconds: _keyTime += 20),
    );

void _sendKeys(List<KeyEvent> events) {
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
  'chevronDown': LucideIcons.chevronDown,
  'pencil': LucideIcons.pencil,
  'eye': LucideIcons.eye,
  'radar': LucideIcons.radar,
  'square': LucideIcons.square,
  'type': LucideIcons.type,
  'camera': LucideIcons.camera,
  'play': LucideIcons.play,
  'pause': LucideIcons.pause,
  'image': LucideIcons.image,
  'clipboard': LucideIcons.clipboard,
  'plus': LucideIcons.plus,
};

// Stands in for the OS save dialog: answers with dir/fileName, or dir/typedName
// as a user who renamed the file would, and writes the bytes when given, as
// FilePicker does on desktop.
class _FakeSaver extends FilePicker {
  _FakeSaver(this.dir, this.typedName);
  final String dir;
  final String? typedName;

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
    final path = '$dir${Platform.pathSeparator}${typedName ?? fileName}';
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

class _FakeOpener extends FilePicker {
  _FakeOpener(this.filePath);
  final String filePath;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final file = File(filePath);
    _log('PICK $filePath');
    return FilePickerResult([
      PlatformFile(
        path: filePath,
        name: file.uri.pathSegments.last,
        size: file.lengthSync(),
      ),
    ]);
  }
}

// Cloud state.

/// The links opened, kept here so a run never opens a browser on the desktop
/// it shares.
final _openedLinks = <String>[];

class _RecordingUrlLauncher extends UrlLauncherPlatform {
  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    _openedLinks.add(url);
    return true;
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    _openedLinks.add(url);
    return true;
  }
}

/// Every item on the open page that takes a caption.
List<PlacedWidget> _placedItems() {
  final c = appProviderContainer;
  return [
    ...c.read(agentProvider),
    ...c.read(abilityProvider),
    ...c.read(textProvider),
    ...c.read(placedImageProvider).images,
    ...c.read(utilityProvider),
  ];
}

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
      await _tap(
        _point(step, name),
        secondary: step['button'] == 'secondary',
        hold: Duration(
          milliseconds: (((step['hold'] ?? 0.06) as num) * 1000).round(),
        ),
      );
    case 'hoverAt':
      await _hover(_point(step, name));
    case 'tapDoor':
      await _tap(_doorPoint(value as String));
    case 'hoverDoor':
      await _hover(_doorPoint(value as String));
    case 'dragAt':
      await _drag([_point(step, name), _point(step, name, 2)]);
    case 'path':
      await _drag([
        for (final p in (value as List).cast<List>())
          Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
      ], stepsPerLeg: 6, shotWhileHeld: step['held'] as String?);
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
      await _expectKeyFocus();
      _press([value as String]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _frames();
    case 'keyCombo':
      await _expectKeyFocus();
      _press((value as List).cast<String>());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _frames();
    case 'holdKey':
      _sendKeys([_keyDown(value as String)]);
      await _frames();
    case 'letGoKey':
      _sendKeys([_keyUp(value as String)]);
      await _frames();
    case 'typeText':
      EditableTextState? field;
      void visit(Element element) {
        if (element case StatefulElement(:final EditableTextState state)) {
          field = state;
        }
        element.visitChildElements(visit);
      }
      WidgetsBinding.instance.rootElement?.visitChildElements(visit);
      final text = value as String;
      field!.userUpdateTextEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
        SelectionChangedCause.keyboard,
      );
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
    case 'addAbility':
      final id = value as String;
      final abilities = c.read(abilityProvider.notifier);
      final agent = AgentType.values.byName(step['agent'] as String);
      abilities.addAbility(
        PlacedAbility(
          data: AgentData.agents[agent]!.abilities[step['slot'] as int],
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
    case 'addHighTide':
      final id = value as String;
      final abilities = c.read(abilityProvider.notifier);
      abilities.addAbility(
        PlacedAbility(
          data: AgentData.agents[AgentType.harbor]!.abilities[1],
          position: const Offset(500, 500),
          id: id,
          isAlly: true,
          wallPath: step['wall'] == null
              ? null
              : [
                  for (final point in step['wall'] as List)
                    Offset(
                      ((point as List)[0] as num).toDouble(),
                      (point[1] as num).toDouble(),
                    ),
                ],
        ),
      );
      await _place(
        id,
        _point(step, 'at'),
        (p) => abilities.updatePosition(p, id),
      );
    case 'addUtility':
      final id = value as String;
      final utilities = c.read(utilityProvider.notifier);
      final type = UtilityType.values.byName(step['type'] as String);
      utilities.addUtility(
        PlacedUtility(
          type: type,
          position: const Offset(500, 500),
          id: id,
          customWidth: type == UtilityType.customRectangle
              ? ((step['size'] ?? 2) as num).toDouble()
              : null,
          customLength: type == UtilityType.customRectangle
              ? ((step['size'] ?? 2) as num).toDouble()
              : null,
          customDiameter: type == UtilityType.customCircle ? 10 : null,
          customColorValue:
              type == UtilityType.spike ? null : 0xFF22C55E,
          customOpacityPercent: type == UtilityType.spike ? null : 30,
          mapDoor: step['door'] as String?,
        ),
      );
      await _place(
        id,
        _point(step, 'at'),
        (p) => utilities.updatePosition(p, id),
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
      final legacy = step['legacy'] == true;
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
                id: legacy ? 'lo$n' : 'll$n',
                ability: PlacedAbility(
                  id: legacy ? 'lo$n' : 'll$n',
                  data: smoke,
                  position: to,
                  isAlly: true,
                  lineUpID: legacy ? 'lo$n' : 'll$n',
                ),
              ),
            ],
            links: [
              LineUpLink(
                id: legacy ? 'lo$n' : 'lk$n',
                originId: 'lo$n',
                landingId: legacy ? 'lo$n' : 'll$n',
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
      final id = _itemId(value as String);
      final from = _itemCenter(id);
      await _drag([
        from,
        step['toWorld'] == null
            ? from + _point(step, 'by')
            : _canvasPointOnScreen(_point(step, 'toWorld')),
      ]);
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
    case 'shareLink':
      final code = generateIcarusShareCode();
      await c.read(convexStrategyRepositoryProvider).createShareLink(
            targetType: 'strategy',
            targetPublicId: c.read(strategyProvider).strategyId!,
            token: code,
            role: value as String,
          );
      await File(step['file'] as String).writeAsString(code);
    case 'openShareLink':
      final code = (await File(value as String).readAsString()).trim();
      await c.read(shareLinkControllerProvider.notifier).handleIncomingUri(
            Uri.parse(
              buildIcarusShareLink(code, origin: icarusProductionShareOrigin),
            ),
            source: 'drive',
          );
    case 'importReplay':
      await c.read(replayLibraryProvider.notifier).import(value as String);
    case 'dropFiles':
      // The messages the native drop target sends, so the drop arrives where
      // Windows delivers one.
      final at = _point(step, 'at');
      void send(String method, Object? arguments) => ui.channelBuffers.push(
            'desktop_drop',
            const StandardMethodCodec()
                .encodeMethodCall(MethodCall(method, arguments)),
            (_) {},
          );
      send('entered', [at.dx, at.dy]);
      await _frames();
      send('performOperation', (value as List).cast<String>());
    case 'fakeSaveDir':
      FilePicker.platform = _FakeSaver(value as String, step['as'] as String?);
    case 'fakePick':
      FilePicker.platform = _FakeOpener(value as String);
    case 'exportIca':
      final id = c.read(strategyProvider).strategyId!;
      await c.read(strategyProvider.notifier).forceSaveNow(id);
      await StrategyImportExportService(c)
          .zipStrategy(id: id, outputFilePath: value as String);
    case 'importIca':
      await StrategyImportExportService(c).loadFromFilePath(value as String);
    case 'clipboard':
      final result = await Process.run('pwsh', [
        '-NoProfile',
        '-STA',
        '-File',
        Platform.environment['ICARUS_DRIVE_SET_CLIPBOARD']!,
        value as String,
        if (step['file'] == true) '-File',
      ]);
      if (result.exitCode != 0) throw StateError('${result.stderr}');
    case 'openLineup':
      unawaited(
        showDialog<void>(
          context: _elementOf((w) => w is InteractiveMap),
          builder: (_) => CreateLineupDialog(linkId: value as String),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _frames();
    case 'mark':
      _marks[value as String] = Stopwatch()..start();
    case 'watchPicture':
      _pictureWatches.add(
        _watchPicture(value as String, step['gone'] as String?),
      );
    case 'watchFrames':
      if (value == true) {
        _watchingFrames = true;
        unawaited(_watchFrames());
      } else {
        _watchingFrames = false;
        await _frames();
        _log(
          'FRAMES ${step['tag']} frames=$_framesSeen '
          'worstGap=${_worstFrameGap.inMilliseconds} ms '
          'over50ms=$_gapsOver50',
        );
      }
    case 'expectPicturesIn':
      final folder = await PlacedImageProvider.getImageFolder(
        c.read(strategyProvider).strategyId!,
      );
      if (!path.isWithin(value as String, folder.path)) {
        throw StateError('pictures are in ${folder.path}');
      }
      if (folder.listSync().isEmpty) {
        throw StateError('no pictures in ${folder.path}');
      }
    case 'logImages':
      await _logImages(value as String);
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
    case 'framesStart':
      _frameTimings.clear();
      SchedulerBinding.instance.addTimingsCallback(_frameTimings.addAll);
    case 'framesLog':
      SchedulerBinding.instance.removeTimingsCallback(_frameTimings.addAll);
      String times(Iterable<Duration> durations) {
        final ms = [for (final d in durations) d.inMicroseconds / 1000]..sort();
        if (ms.isEmpty) return 'none';
        String at(double share) =>
            ms[((ms.length - 1) * share).round()].toStringAsFixed(2);
        return 'p50 ${at(.5)} p90 ${at(.9)} p99 ${at(.99)} worst ${at(1)}';
      }
      _log('FRAMES $value n=${_frameTimings.length} '
          'build ${times(_frameTimings.map((t) => t.buildDuration))} '
          'raster ${times(_frameTimings.map((t) => t.rasterDuration))}');
    case 'burst':
      for (var i = 0; i < ((step['count'] ?? 10) as int); i++) {
        await _run({'shot': '$value-${i.toString().padLeft(3, '0')}.png'});
        await Future<void>.delayed(
          Duration(milliseconds: (step['every'] ?? 100) as int),
        );
      }
    case 'logLineups':
      final lineUps = c.read(lineUpProvider);
      String at(Offset? p) => p == null
          ? 'gone'
          : '(${p.dx.toStringAsFixed(1)}, ${p.dy.toStringAsFixed(1)})';
      _log('LINEUPS $value ${[
        for (final link in lineUps.links)
          '${link.id} '
              'origin@${at(lineUps.originById(link.originId)?.agent.position)} '
              'landing@${at(lineUps.landingById(link.landingId)?.ability.position)}',
      ]}');
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
    case 'setCaption':
      setCaption(c, value as String, step['text'] as String);
    case 'logCard':
      final root = RendererBinding.instance.renderViews.first.child;
      _log('CARD $value ${c.read(captionCardProvider)} '
          'zoom=${c.read(screenZoomProvider)} links=$_openedLinks chrome=${[
        if (root is RenderBox)
          for (final rect in c.read(canvasItemRegistryProvider).chromeIn(root))
            '${rect.left.round()},${rect.top.round()},'
                '${rect.right.round()},${rect.bottom.round()}',
      ]}');
    case 'logCaptions':
      _log('CAPTIONS $value ${jsonEncode({
            for (final item in _placedItems()) item.id: item.caption,
          })}');
    case 'logWalls':
      _log('WALLS $value ${[
        for (final ability in c.read(abilityProvider))
          '${ability.id}@(${ability.position.dx.toStringAsFixed(1)}, '
              '${ability.position.dy.toStringAsFixed(1)}) '
              'wall=${ability.wallPath?.map(
                    (p) => '(${p.dx.toStringAsFixed(1)}, '
                        '${p.dy.toStringAsFixed(1)})',
                  ).toList()}',
      ]}');
    case 'logDoors':
      _log('DOORS $value ${changedMapDoors(
        c.read(utilityProvider),
        c.read(mapProvider).currentMap,
      ).toList()..sort()} rows=${c.read(utilityProvider).where(
            (utility) => utility.mapDoor != null,
          ).length}');
    case 'logUtilities':
      _log('UTILITIES $value ${[
        for (final utility in c.read(utilityProvider))
          '${utility.id} ${utility.type.name}@'
              '(${utility.position.dx.toStringAsFixed(1)}, '
              '${utility.position.dy.toStringAsFixed(1)}) '
              'door=${utility.mapDoor}',
      ]}');
    case 'logPage':
      _log(
        'PAGE $value strategy=${c.read(strategyProvider).strategyName} '
        'agents=${c.read(agentProvider).length} '
        'abilities=${c.read(abilityProvider).length} '
        'texts=${c.read(textProvider).length} '
        'drawings=${c.read(drawingProvider).elements.length} '
        'images=${c.read(placedImageProvider).images.length} '
        'utilities=${[
          for (final u in c.read(utilityProvider))
            '${u.type.name}/${u.angle}@'
                '${u.position.dx.toStringAsFixed(1)},'
                '${u.position.dy.toStringAsFixed(1)}'
                '${u.customLength == null ? '' : ' ${u.customLength!.toStringAsFixed(1)}x${u.customWidth!.toStringAsFixed(1)}'}',
        ]} '
        'lineups=${c.read(lineUpProvider).graph.links.length} '
        'selected=${c.read(canvasSelectionProvider).length} '
        'tool=${c.read(interactionStateProvider).name}',
      );
    case 'expectSelected':
      final selected = c.read(canvasSelectionProvider).length;
      if (selected != value) {
        throw StateError('$selected selected, expected $value');
      }
    case 'expectText':
      final count = _countOf(
        (widget) => widget is RichText && _isText(widget, value as String),
      );
      if (count != step['count']) {
        throw StateError('"$value" $count times, expected ${step['count']}');
      }
    case 'expectAgents':
      final agents = c.read(agentProvider).length;
      if (agents != value) throw StateError('$agents agents, expected $value');
    case 'expectInView':
      final canvas = _canvasLayer();
      final viewer = _renderOf<InteractiveViewer>();
      final view = viewer.localToGlobal(Offset.zero) & viewer.size;
      final outlines = <String, Rect>{};
      for (final (:item, :corners)
          in c.read(canvasItemRegistryProvider).itemsIn(canvas)) {
        final onScreen = corners.map(canvas.localToGlobal).toList();
        var drawn = Rect.fromPoints(onScreen[0], onScreen[2]);
        for (final corner in onScreen) {
          drawn = drawn.expandToInclude(Rect.fromPoints(corner, corner));
        }
        outlines[item.id] = outlines[item.id]?.expandToInclude(drawn) ?? drawn;
      }
      _log('IN-VIEW view=${view.left},${view.top},${view.right},${view.bottom} ${{
        for (final MapEntry(key: id, value: drawn) in outlines.entries)
          id: '${drawn.left.toStringAsFixed(1)},'
              '${drawn.top.toStringAsFixed(1)},'
              '${drawn.right.toStringAsFixed(1)},'
              '${drawn.bottom.toStringAsFixed(1)}',
      }}');
      if (outlines.length != value) {
        throw StateError('${outlines.length} items, expected $value');
      }
      for (final MapEntry(key: id, value: drawn) in outlines.entries) {
        if (step['only'] case final String only when only != id) continue;
        if (view.intersect(drawn) != drawn) {
          throw StateError('$id is out of view: $drawn');
        }
      }
    case 'expectItem':
      final id = _itemId(value as String);
      final items = _placedItems().where((item) => item.id == id);
      final at = items.isEmpty
          ? 'gone'
          : '(${items.first.position.dx.toStringAsFixed(1)}, '
              '${items.first.position.dy.toStringAsFixed(1)})';
      _log('ITEM $value $at');
      if (items.isEmpty != (step['gone'] == true)) {
        throw StateError('$value is $at');
      }
    case 'expectDead':
      final dead = c
          .read(agentProvider)
          .where((agent) => agent.state == AgentState.dead)
          .length;
      if (dead != value) throw StateError('$dead dead agents, expected $value');
    case 'expectImages':
      final images = c.read(placedImageProvider).images.length;
      final inLineups = [
        for (final link in c.read(lineUpProvider).links) ...link.images,
      ].length;
      if (images != value) {
        throw StateError('$images pictures, expected $value');
      }
      if (step['lineups'] case final int lineups when inLineups != lineups) {
        throw StateError('$inLineups lineup pictures, expected $lineups');
      }
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

final _marks = <String, Stopwatch>{};
final _pictureWatches = <Future<void>>[];

/// Waits for a pasted picture to be drawn: the only image this large on
/// screen, whether in a dialog or on the canvas.
Future<void> _watchPicture(String mark, String? gone) async {
  bool drawn() =>
      _elementOrNull((w) => w is RawImage && (w.image?.width ?? 0) >= 500) !=
      null;

  bool left() {
    if (gone == null) return true;
    return _elementOrNull((w) => _isText(w, gone)) == null;
  }

  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!(left() && drawn())) {
    if (DateTime.now().isAfter(deadline)) {
      _failedSteps++;
      _log('FAIL $mark: the picture was never drawn');
      return;
    }
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
  }
  _log('TIMED $mark drawn after ${_marks[mark]!.elapsedMilliseconds} ms');
}

var _watchingFrames = false;
var _framesSeen = 0;
var _gapsOver50 = 0;
var _worstFrameGap = Duration.zero;

/// Asks for frames without a pause and times each from its start to the end
/// of its raster, so a stall on either thread shows.
Future<void> _watchFrames() async {
  _framesSeen = 0;
  _gapsOver50 = 0;
  _worstFrameGap = Duration.zero;
  void note(List<ui.FrameTiming> timings) {
    for (final timing in timings) {
      final took = timing.totalSpan;
      _framesSeen++;
      if (took > _worstFrameGap) _worstFrameGap = took;
      if (took.inMilliseconds > 50) _gapsOver50++;
    }
  }

  SchedulerBinding.instance.addTimingsCallback(note);
  var last = Stopwatch()..start();
  while (_watchingFrames) {
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
    final gap = last.elapsed;
    last = Stopwatch()..start();
    if (gap > _worstFrameGap) _worstFrameGap = gap;
    if (gap.inMilliseconds > 50) _gapsOver50++;
  }
  SchedulerBinding.instance.removeTimingsCallback(note);
}

/// Every picture on the page and in its lineups, with the file it saved and
/// the box it draws in.
Future<void> _logImages(String tag) async {
  final c = appProviderContainer;
  final strategy = c.read(strategyProvider);
  Future<String> file(String id, String? extension) async {
    final saved = File(
      PlacedImageProvider.buildImageFilePath(
        (await PlacedImageProvider.getImageFolder(strategy.strategyId!)).path,
        id,
        extension ?? '',
      ),
    );
    return saved.existsSync() ? '${saved.lengthSync()} bytes' : 'no file';
  }

  for (final image in c.read(placedImageProvider).images) {
    final box = _elementOrNull((w) => w.key == ValueKey('entity-${image.id}'))
        ?.findRenderObject();
    _log(
      'IMAGE $tag id=${image.id} picture=${image.pictureId} '
      'ext=${image.fileExtension} aspect=${image.aspectRatio} '
      'scale=${image.scale} '
      'at=(${image.position.dx}, ${image.position.dy}) '
      'box=${box is RenderBox ? _size(box.size) : 'none'} '
      'file=${await file(image.pictureId, image.fileExtension)}',
    );
  }
  for (final link in c.read(lineUpProvider).links) {
    for (final image in link.images) {
      _log(
        'LINEUP-IMAGE $tag link=${link.id} id=${image.id} '
        'ext=${image.fileExtension} '
        'file=${await file(image.id, image.fileExtension)}',
      );
    }
  }
  for (final job in c.read(cloudMediaUploadQueueProvider).jobs) {
    _log(
      'JOB $tag ${job.assetPublicId} ${job.state.name} ${job.mimeType} '
      'bytes=${job.byteSize} attempts=${job.attempts} error=${job.lastError}',
    );
  }
}

Element? _elementOrNull(bool Function(Widget) test) {
  Element? found;
  void visit(Element element) {
    if (test(element.widget)) found = element;
    if (found == null) element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return found;
}

Element _elementOf(bool Function(Widget) test) =>
    _elementOrNull(test) ?? (throw StateError('nothing on screen matches'));

/// The driver's name for item [id]: pictures are given theirs by the app.
String _itemId(String id) => id == 'lastImage'
    ? appProviderContainer.read(placedImageProvider).images.last.id
    : id;

/// Where the point [world] of the canvas, as drawn, is in the window.
Offset _canvasPointOnScreen(Offset world) => _canvasLayer()
    .localToGlobal(CoordinateSystem.instance.coordinateToScreen(world));

RenderBox _canvasLayer() => _renderOf<CanvasSelectionLayer>();

RenderBox _renderOf<T extends Widget>() {
  RenderBox? box;
  void visit(Element element) {
    if (element.widget is T) {
      box = element.findRenderObject() as RenderBox?;
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return box ?? (throw StateError('no $T on screen'));
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
