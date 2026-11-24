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
//   {"tapWords": t, "nth": n?, "times": k?, "touch": b?, "button": "secondary"?}
//                                      where a longer text draws t, such as an
//                                      address in a text box, on t's first line;
//                                      times 2 is a double-click, touch a finger
//   {"hoverWords": t}                  {"dragWords": t, "by": [dx, dy]}
//   {"dragAt": [x1, y1, x2, y2]}       {"path": [[x, y], ...], "held": png?}
//                                      held: a shot before letting go
//   {"scrollAt": [x, y, dy]}           {"key": name}  {"keyCombo": [names]}
//   {"panScroll": [x, y, dy, ms]}      a trackpad swipe of dy over ms, then
//                                      lets go so the list flings, as on a Mac
//   {"holdKey": name}  {"letGoKey": name}  a key held across other steps
//   {"resize": [w, h]}                 the window
//   {"typeText": t}                    replaces the text in the last text field
// Editor content
//   {"addAgent": id, "at": [x, y], "agent": "jett"?, "cone": "viewCone90"?, "facing": degrees?, "length": n?, "enemy": b?}
//   {"addHighTide": id, "at": [x, y], "wall": [[dx, dy], ...]?}
//   {"addSmoke": id, "at": [x, y]}     {"addText": id, "at": [x, y], "text": t?}
//   {"setCaption": id, "text": t}      what the caption dialog's Done does
//   {"addUtility": id, "type": name, "at": [x, y], "door": id?, "zone": b?}
//                                      spike, customRectangle, customCircle
//   {"addImage": path, "at": [x, y]}   {"addLineup": n, "legacy": b?}  two lineups, ids
//                                      lo1{n}, lo2{n}; legacy ones share one id per lineup
//   {"addAbility": id, "agent": name, "slot": n, "at": [x, y], "facing": degrees?}
//   {"dragAgent": id, "by": [dx, dy], "steps": n?}  {"hoverAgent": id}
//   {"dragAgent": id, "toWorld": [x, y], "held": shot?}  shot: saved before letting go
//                                      drops the middle of any placed item at this
//                                      point of the canvas as drawn, 1778 by 1000;
//                                      the id lastImage is the newest picture
// Library and cloud
//   {"signIn": true}                   ICARUS_DRIVE_EMAIL / ICARUS_DRIVE_PASSWORD
//   {"refreshSession": true}           refreshes the sign-in, as Supabase does about once an hour
//   {"reconnect": true}                drops the cloud connection and dials it again
//   {"newLocal": map, "name": n}       {"newCloud": name, "map": m?}
//   {"newCloudFolder": name}           {"openCloudFolder": name}
//   {"outboxWrites": b}                with false, the outbox refuses writes
//   {"dropOpenPage": 1}                the open local page leaves the library
//   {"shareLink": role, "file": path}  makes a link to the open strategy and
//                                      writes its code to the file
//   {"openShareLink": path}            opens the link whose code is in the file
//   {"importReplay": path}             {"fakeSaveDir": dir, "as": name?}
//   {"openReplay": path}               adds it as Add Replay does and opens it
//   {"seekReplay": ms}                 pauses the open replay at ms
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
//   {"shot": png}                      {"burst": prefix, "count": n?, "every": ms?,
//                                       "during": step?}  shots while step runs, each logged with the page transition's progress
//   {"slowMotion": k}                  animations run k times slower; 1 is real speed
//   {"logWalls": tag}                  every ability's position and wall path
//   {"logUtilities": tag}              every utility's type, position and door
//   {"logDoors": tag}                  the map doors changed on the page
//   {"logCoords": tag}                 {"logPage": tag}  {"probe": tag}  {"texts": 1}
//   {"logCaptions": tag}  {"logCard": tag}  every caption; the open card
//   {"logLineups": tag}                {"logImages": tag}
//   {"framesStart": 1} / {"framesLog": tag}   frame build and raster times between
//                                      them: p50, p90, p99, worst, in ms
//   {"expectText": t, "count": n}      fails unless t is on screen n times
//   {"expectSelected": n}              fails unless n items are selected
//   {"expectOpened": [urls]}           fails unless these are the links opened so
//                                      far, in order; a run opens no browser
//   {"expectEditing": b}               fails unless a text field has the keyboard,
//                                      or with false, unless none has
//   {"logTexts": tag}                  every text box's position, width and text
//   {"expectAgents": n}  {"expectDead": n}  n agents on the page, n dead
//   {"expectInView": n, "only": id?,   fails unless n items are drawn, all of
//    "middles": b?}                    them in the map's view; logs their outlines.
//                                      With only, checks that item, and the page
//                                      can have more. With middles, only each
//                                      item's middle has to be in view
//   {"expectOnMapLine": id}            fails unless the agent or ability's dot is
//                                      on a line the map draws; logs how far off
//   {"expectOpacity": id, "percent": n, "seconds": s?}
//                                      fails unless the shape is drawn at n
//                                      percent, waiting up to s seconds for it
//   {"expectTag": id, "color": hex?, "seconds": s?}
//                                      fails unless the text box or picture's tag
//                                      is this color, six lowercase hex digits,
//                                      or gray without one; lastImage as above
//   {"expectItem": id, "gone": b?}     fails unless the item is on the page; gone flips it
//   {"expectRow": id, "gone": b?, "copy": b?, "version": n?}  the same for the server's copy of the page; copy: a copy of id
//   {"sendRow": id, "kind": k, "data": {}, "version": n?}  adds or replaces a row as another build writes it
//   {"expectImages": n, "lineups": m?} fails unless n pictures are on the page, m in lineups
//   {"exit": 1}
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show showDialog;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/dev/drive/drive_checks.dart';
import 'package:icarus/dev/drive/drive_frames.dart';
import 'package:icarus/dev/drive/drive_cloud_store.dart';
import 'package:icarus/library_store/slowed_engine.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/dev/drive/drive_action_ops.dart';
import 'package:icarus/dev/drive/drive_library_store.dart';
import 'package:icarus/dev/drive/drive_screens.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/services/guarded_sign_out.dart';
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
import 'package:icarus/providers/map_lines_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/widgets/replay/replay_dock.dart';
import 'package:icarus/widgets/replay/replay_library_content.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart'
    hide PageTransitionState;
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/share/share_link_format.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/canvas_shows.dart';
import 'package:icarus/services/image_file_name.dart' show strategyFolderPath;
import 'package:icarus/services/strategy_folders.dart';
import 'package:icarus/library_store/canvas_units.dart' show cloneStrategy;
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
  _runFrames.start();
  if (_startsByHoldingTheList(script)) holdListAtLaunch(appProviderContainer);
  unawaited(_play(script));
}

bool _startsByHoldingTheList(String script) {
  try {
    return switch (jsonDecode(File(script).readAsStringSync())) {
      [{'holdListOnHive': true}, ...] => true,
      _ => false,
    };
  } on Object {
    return false;
  }
}

final _runFrames = RunFrames();

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
final _cloudStore = CloudStoreLog();

void _logCloudStore(List<CloudStoreLine> lines) {
  for (final line in lines) {
    if (line.problem) _failedSteps++;
    _log(line.problem ? 'FAIL ${line.text}' : line.text);
  }
}

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
  _countLibraryBoxEvents();
  _log(await firstFrameLine(appProviderContainer));
  if (_cloudStore.isOn(appProviderContainer)) {
    _log(_cloudStore.sends(appProviderContainer)
        ? 'CLOUDSTORE switch send'
        : 'CLOUDSTORE switch shadow');
  }
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
    _logScreensIfChanged('step $_steps');
    switch (await mirrorDrained(appProviderContainer)) {
      case MirrorWait.drained:
        _logScreensIfChanged('step $_steps after the mirror drained');
      case MirrorWait.stillBusy:
        _failedSteps++;
        _log('FAIL step $_steps: the mirror had not drained 30 s after it');
      case MirrorWait.notMirroring:
        break;
    }
    _logCloudStore(_cloudStore.drain(appProviderContainer));
    await _flush();
  }
  final cloudEnd =
      _cloudStore.end(appProviderContainer, lastStep: DateTime.now());
  await Future.wait(_pictureWatches);
  _logCloudStore(await cloudEnd);
  _log(_runFrames.stop());
  _log(buildsLine());
  try {
    (await mirrorEndLines(appProviderContainer)).forEach(_log);
  } on StoreStepFailed catch (failed) {
    _failedSteps++;
    failed.problems.forEach(_log);
  }
  try {
    listEndLines(appProviderContainer).forEach(_log);
  } on StoreStepFailed catch (failed) {
    _failedSteps++;
    failed.problems.forEach(_log);
  }
  final refusals =
      appProviderContainer.read(canvasShowsProvider.notifier).refusals;
  _log('CANVAS nothing shown '
      '${refusals.where((r) => r.what == 'nothing shown').length} times, a '
      'click ignored during an open '
      '${refusals.where((r) => r.what != 'nothing shown').length} times');
  for (final refusal in refusals) {
    _log('CANVAS $refusal');
  }
  try {
    if (await closeStoreLine(appProviderContainer) case final line?) {
      if (line.startsWith('FAIL')) _failedSteps++;
      _log(line);
    }
  } catch (error) {
    _failedSteps++;
    _log('FAIL closing the store: $error');
    _logCloudStore(_cloudStore.closeFailed(appProviderContainer, error));
  }
  _logCloudStore(await _cloudStore.readBack(appProviderContainer));
  final problems = _flutterErrors + _failedSteps + _misplaced.length;
  _log(
    'SUMMARY steps=$_steps failed=$_failedSteps '
    'flutterErrors=$_flutterErrors misplaced=${_misplaced.length} '
    '${problems == 0 ? 'CLEAN' : 'PROBLEMS'}',
  );
  await _flush();
  if (steps.any((step) => step is Map && step['exit'] != null)) exit(0);
}

var _libraryLogged = <String>[];
var _pagesBarLogged = <String>[];
String? _listSourceLogged;

void _logListSource(String label) {
  final source = listSourceName(appProviderContainer);
  if (source == null || source == _listSourceLogged) return;
  _listSourceLogged = source;
  _log('LISTING $label drawn from $source');
}

void _logLibrary(String label, List<String> library) {
  _logListSource(label);
  _libraryLogged = library;
  _log('LIBRARY $label ${library.length} on screen');
  for (final line in library) {
    _log('LIBRARY $label $line');
  }
  _logGrid(label, always: true);
}

var _gridLogged = <String>[];

void _logGrid(String label, {bool always = false}) {
  final grid = gridSources(appProviderContainer);
  if (grid == null) return;
  final lines = gridLines('', grid);
  if (!always && listEquals(lines, _gridLogged)) return;
  _gridLogged = lines;
  gridLines(label, grid).forEach(_log);
}

void _logPagesBar(String label, List<String> bar) {
  _pagesBarLogged = bar;
  _log('PAGESBAR $label ${bar.isEmpty ? 'none' : bar.join(' | ')}');
}

var _buildsLogged = '';

void _countLibraryBoxEvents() {
  final [strategies, folders] = const LocalLibrary().boxEvents();
  strategies.listen((event) {
    countLibraryBoxEvent('strategies-box');
    if (event case BoxEvent(:final key)
        when key == appProviderContainer.read(strategyProvider).strategyId) {
      countLibraryBoxEvent('open-strategy-box');
    }
  });
  folders.listen((_) => countLibraryBoxEvent('folders-box'));
}

void _logScreensIfChanged(String label) {
  _logListSource(label);
  final library = libraryOnScreen();
  if (!listEquals(library, _libraryLogged)) {
    _logLibrary(label, library);
  } else {
    _logGrid(label);
  }
  final bar = pagesBarOnScreen();
  if (!listEquals(bar, _pagesBarLogged)) _logPagesBar(label, bar);
  final builds = buildCounts();
  if (builds != _buildsLogged) {
    _buildsLogged = builds;
    _log('BUILDS $label $builds');
  }
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

Future<void> _checkItems() async {
  await _frames();
  if (misplacedItems(appProviderContainer).isEmpty) return;
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _frames();
  for (final line in misplacedItems(appProviderContainer)) {
    if (_misplaced.add(line)) _log('MISPLACED $line');
  }
}

Future<PageTransitionState> _shot(String path) async {
  await _frames();
  final transition = appProviderContainer.read(transitionProvider);
  final view = RendererBinding.instance.renderViews.first;
  final layer =
      // The root layer is what the window shows.
      // ignore: invalid_use_of_protected_member
      view.debugLayer as OffsetLayer? ?? (view.layer as OffsetLayer);
  final image = await layer.toImage(
    Offset.zero & (view.size * view.flutterView.devicePixelRatio),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  return transition;
}

void _pressMouse(Offset at, {int buttons = kPrimaryMouseButton}) {
  final pointer = _pointer++;
  final binding = GestureBinding.instance;
  _addMouse(pointer, at);
  binding.handlePointerEvent(PointerHoverEvent(
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
    position: at,
  ));
  binding.handlePointerEvent(PointerDownEvent(
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
    position: at,
  ));
  binding.handlePointerEvent(PointerUpEvent(
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
    position: at,
  ));
}

Future<void> _mapThenOpen(Map<String, dynamic> step) async {
  final c = appProviderContainer;
  final strategies = c.read(strategyProvider.notifier);
  final repository = c.read(convexStrategyRepositoryProvider);
  final listing = c.listen(cloudStrategiesProvider, (_, __) {});
  String idOf(String name) =>
      (c.read(cloudStrategiesProvider).valueOrNull ?? const [])
          .firstWhere((entry) => entry.strategy.name == name)
          .strategy
          .id;
  bool listed(String name) =>
      (c.read(cloudStrategiesProvider).valueOrNull ?? const [])
          .any((entry) => entry.strategy.name == name);
  await _waitFor(
    () =>
        listed(step['mapThenOpen'] as String) && listed(step['from'] as String),
    30,
  );
  final opened = idOf(step['mapThenOpen'] as String);
  final left = idOf(step['from'] as String);
  listing.close();
  final runs = (step['runs'] ?? 50) as int;
  final byBackButton = (step['by'] ?? 'back') == 'back';
  final targets = [
    for (final name in (step['maps'] as List).cast<String>())
      MapValue.values.byName(name),
  ];
  final restAt = _point(step, 'restAt');
  final shots = step['shots'] as String?;
  String ms(int micros) => (micros / 1000).toStringAsFixed(1);
  Future<String> serverMap(String id) async =>
      (await repository.fetchShell(id)).header.mapData;
  Future<void> openAndSettle(String id) async {
    if (!await strategies.openCloudStrategy(id)) {
      throw StateError('$id did not open');
    }
    await _waitFor(
      () => !c.read(strategyPageSessionProvider).isApplyingPage,
      30,
    );
    await _frames();
  }

  final outcomes = <String, int>{};
  final patchWaits = <int>[];
  final openStarts = <int>[];
  for (var run = 1; run <= runs; run++) {
    await openAndSettle(opened);
    await openAndSettle(left);
    final openedBefore = await serverMap(opened);
    final leftBefore = await serverMap(left);
    final target = targets.firstWhere(
      (map) =>
          Maps.mapNames[map] != openedBefore &&
          Maps.mapNames[map] != leftBefore &&
          map != c.read(mapProvider).currentMap,
    );
    final targetName = Maps.mapNames[target]!;
    Future<Offset> shown(String text, String shot) async {
      try {
        return _centerOf((w) => _isText(w, text));
      } on StateError {
        if (shots != null) await _shot('$shots/maprace-$run-$shot.png');
        rethrow;
      }
    }

    await _tap(await shown(
      Maps.mapNames[c.read(mapProvider).currentMap]!.toUpperCase(),
      'no-map-button',
    ));
    final tile = await shown(targetName.toUpperCase(), 'no-tile');
    if (shots != null && run <= 2)
      await _shot('$shots/maprace-$run-picker.png');
    final clock = Stopwatch();
    int? patchAt;
    String? patchUnder;
    int? openAt;
    final subscription = c.listen(strategyOpQueueProvider, (_, next) {
      if (openAt == null && next.strategyPublicId == opened) {
        openAt = clock.elapsedMicroseconds;
      }
      if (patchAt != null) return;
      for (final pending in next.pending) {
        if (pending.op case StrategyPatchOp(:final payload)
            when payload['mapData'] == targetName) {
          patchAt = clock.elapsedMicroseconds;
          patchUnder = next.strategyPublicId;
        }
      }
    });
    clock.start();
    _pressMouse(tile);
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
    final mapAfterTap = c.read(mapProvider).currentMap;
    if (byBackButton) {
      _pressMouse(restAt, buttons: kBackMouseButton);
    } else {
      unawaited(strategies.openCloudStrategy(opened));
    }
    await _waitFor(
      () =>
          c.read(strategyProvider).strategyId == opened &&
          !c.read(strategyPageSessionProvider).isApplyingPage,
      30,
    );
    String? leftAfter;
    String? openedAfter;
    final settleBy = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(settleBy)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      leftAfter = await serverMap(left);
      openedAfter = await serverMap(opened);
      if (leftAfter == targetName || openedAfter == targetName) break;
    }
    subscription.close();
    if (shots != null && run <= 2) await _shot('$shots/maprace-$run-after.png');
    final outcome = openedAfter == targetName
        ? 'the opened strategy took the change'
        : leftAfter == targetName
            ? 'the changed strategy kept it'
            : 'neither has it';
    outcomes[outcome] = (outcomes[outcome] ?? 0) + 1;
    if (patchAt case final at?) patchWaits.add(at);
    if (openAt case final at?) openStarts.add(at);
    _log('MAPRACE run $run (${byBackButton ? 'back button' : 'direct open'}): '
        '$left $leftBefore -> $targetName (canvas ${Maps.mapNames[mapAfterTap]} a frame after the tap); '
        'patch queued ${patchAt == null ? 'never seen' : '${ms(patchAt!)} ms after the tap, under ${patchUnder == opened ? opened : patchUnder == left ? left : patchUnder}'}; '
        'open began ${openAt == null ? 'never' : '${ms(openAt!)} ms'} after the tap; '
        '$outcome ($left $leftAfter, $opened $openedAfter)');
  }
  patchWaits.sort();
  openStarts.sort();
  String spread(List<int> values) => values.isEmpty
      ? '-'
      : 'median ${ms(values[values.length ~/ 2])} ms, worst ${ms(values.last)} ms';
  _log('MAPRACE summary (${byBackButton ? 'back button' : 'direct open'}): '
      '$runs runs; ${[
    for (final MapEntry(:key, :value) in outcomes.entries) '$key $value',
  ].join(', ')}; tap to patch queued ${spread(patchWaits)}; '
      'tap to open began ${spread(openStarts)}');
  if (step['expectTaken'] case final int expected
      when (outcomes['the opened strategy took the change'] ?? 0) != expected) {
    _failedSteps++;
    _log('FAIL mapThenOpen: the opened strategy took the change '
        '${outcomes['the opened strategy took the change'] ?? 0} times, '
        'expected $expected');
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

double _radians(Object? degrees) =>
    degrees == null ? 0 : (degrees as num) * math.pi / 180;

Offset _point(Map<String, dynamic> step, String key, [int at = 0]) {
  final xy = (step[key] as List).cast<num>();
  return Offset(xy[at].toDouble(), xy[at + 1].toDouble());
}

bool _isText(Widget widget, String text) =>
    (widget is Text &&
        (widget.data ?? widget.textSpan?.toPlainText()) == text) ||
    (widget is RichText && widget.text.toPlainText() == text);

bool _hasKey(Widget widget, String key) => widget.key == ValueKey<String>(key);

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
List<Offset> _centersOf(bool Function(Widget) test) {
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
  return found;
}

Offset _nearest(List<Offset> points, Offset to) {
  if (points.isEmpty) throw StateError('found 0');
  return points.reduce(
    (a, b) => (a - to).distanceSquared <= (b - to).distanceSquared ? a : b,
  );
}

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

/// Where a longer text draws [words]: the middle of their first line, in
/// the [nth] text that holds them.
Offset _wordsPoint(String words, {int nth = 0}) {
  final found = <Offset>[];
  void visit(RenderObject node) {
    if (node is RenderParagraph && node.attached && node.hasSize) {
      final at = node.text.toPlainText().indexOf(words);
      final boxes = at < 0
          ? const <ui.TextBox>[]
          : node.getBoxesForSelection(
              TextSelection(baseOffset: at, extentOffset: at + words.length),
            );
      if (boxes.isNotEmpty) {
        found.add(node.localToGlobal(boxes.first.toRect().center));
      }
    }
    node.visitChildren(visit);
  }

  RendererBinding.instance.renderViews.forEach(visit);
  if (found.length <= nth) {
    throw StateError('"$words" drawn ${found.length} times');
  }
  return found[nth];
}

bool _editing() {
  var editing = false;
  void visit(Element element) {
    if (element case StatefulElement(:final EditableTextState state)) {
      editing = editing || state.widget.focusNode.hasFocus;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return editing;
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

var _pointer = 900;
final _pointerClock = Stopwatch()..start();
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

/// A trackpad swipe: pan-zoom events, one a frame, moving [dy] in all over
/// [over], then the fingers lift, so the list flings the way it does under a
/// real swipe. Waits for the fling to settle.
Future<void> _panScroll(Offset at, double dy, Duration over) async {
  final pointer = _pointer++;
  final binding = GestureBinding.instance;
  // The velocity tracker reads the events' time stamps; without them the
  // swipe has no speed and the list doesn't fling when the fingers lift.
  final clock = Stopwatch()..start();
  Duration now() => _pointerClock.elapsed;
  binding.handlePointerEvent(
    PointerPanZoomStartEvent(
      timeStamp: now(),
      pointer: pointer,
      device: pointer,
      position: at,
    ),
  );
  var pan = Offset.zero;
  while (clock.elapsed < over) {
    await _frames(1);
    final share = clock.elapsed.inMicroseconds / over.inMicroseconds;
    final next = Offset(0, dy * share.clamp(0.0, 1.0));
    binding.handlePointerEvent(
      PointerPanZoomUpdateEvent(
        timeStamp: now(),
        pointer: pointer,
        device: pointer,
        position: at,
        pan: next,
        panDelta: next - pan,
      ),
    );
    pan = next;
  }
  binding.handlePointerEvent(
    PointerPanZoomEndEvent(
      timeStamp: now(),
      pointer: pointer,
      device: pointer,
      position: at,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await _frames();
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

/// Clicks at [at], [times] in a row as a double-click does, or taps there
/// with a finger when [touch].
Future<void> _tap(
  Offset at, {
  bool secondary = false,
  Duration hold = const Duration(milliseconds: 60),
  int times = 1,
  bool touch = false,
  String? markAtRelease,
}) async {
  final pointer = _pointer++;
  final binding = GestureBinding.instance;
  final kind = touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse;
  if (!touch) {
    _addMouse(pointer, at);
    binding.handlePointerEvent(
      PointerHoverEvent(pointer: pointer, kind: kind, position: at),
    );
    await _frames(2);
  }
  for (var i = 0; i < times; i++) {
    if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 80));
    binding.handlePointerEvent(
      PointerDownEvent(
        pointer: pointer,
        kind: kind,
        buttons: secondary ? kSecondaryMouseButton : kPrimaryMouseButton,
        position: at,
      ),
    );
    await Future<void>.delayed(hold);
    if (markAtRelease != null) _marks[markAtRelease] = Stopwatch()..start();
    binding.handlePointerEvent(
      PointerUpEvent(pointer: pointer, kind: kind, position: at),
    );
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await _frames();
}

void _click(Offset at) {
  final pointer = _pointer++;
  final binding = GestureBinding.instance;
  _addMouse(pointer, at);
  binding.handlePointerEvent(PointerHoverEvent(
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
    position: at,
  ));
  binding.handlePointerEvent(PointerDownEvent(
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
    position: at,
  ));
  binding.handlePointerEvent(PointerUpEvent(
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
    position: at,
  ));
}

Future<void> _raceLeave(Map<String, dynamic> step) async {
  final c = appProviderContainer;
  final openedName = step['raceLeave'] as String;
  final leftName = step['from'] as String;
  final pageName = step['page'] as String;
  final runs = (step['runs'] ?? 50) as int;
  final pictures = (step['unusedPictures'] ?? 20) as int;
  StrategyData named(String name) => const LocalLibrary()
      .storedStrategies
      .firstWhere((strategy) => strategy.name == name);
  final left = named(leftName);
  final opened = named(openedName);
  final firstPageId = ([...left.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)))
      .first
      .id;
  List<String> agentsOnFirstPage() => [
        for (final agent in const LocalLibrary()
            .storedStrategy(left.id)!
            .pages
            .firstWhere((page) => page.id == firstPageId)
            .agentData)
          agent.id,
      ];
  String ms(int micros) => (micros / 1000).toStringAsFixed(1);
  var emptied = 0;
  final windows = <int>[];
  final leftAgents = <String>{};
  var mixedFrames = 0;
  var framesWatched = 0;
  var watching = false;
  SchedulerBinding.instance.addPersistentFrameCallback((_) {
    if (!watching) return;
    framesWatched++;
    if (c.read(strategyProvider).strategyId == opened.id &&
        c.read(agentProvider).any((agent) => leftAgents.contains(agent.id))) {
      mixedFrames++;
    }
  });
  for (var run = 1; run <= runs; run++) {
    final original =
        cloneStrategy(const LocalLibrary().storedStrategy(left.id)!);
    if (!await c.read(strategyProvider.notifier).loadFromHive(left.id)) {
      throw StateError('$leftName did not open');
    }
    await _frames();
    final before = agentsOnFirstPage();
    leftAgents
      ..clear()
      ..addAll([for (final agent in c.read(agentProvider)) agent.id]);
    final root = await strategyFoldersRoot();
    final images = Directory(
      path.join(strategyFolderPath(root.path, opened.id), 'images'),
    )..createSync(recursive: true);
    for (var i = 0; i < pictures; i++) {
      File(path.join(images.path, 'race-unused-$run-$i.png'))
          .writeAsBytesSync(List.filled(16384, run % 251));
    }
    final switcher = _point(step, 'switcherAt');
    await _tap(switcher);
    final item = _nearest(_centersOf((w) => _isText(w, openedName)), switcher);
    final page = _centerOf((w) => _isText(w, pageName));
    final clock = Stopwatch();
    int? cleared;
    int? openedAt;
    int? secondClick;
    final subscriptions = [
      c.listen(agentProvider, (_, next) {
        if (next.isEmpty && cleared == null)
          cleared = clock.elapsedMicroseconds;
      }),
      c.listen(strategyProvider.select((state) => state.strategyId), (_, next) {
        if (next == opened.id) openedAt ??= clock.elapsedMicroseconds;
      }),
    ];
    clock.start();
    watching = true;
    _click(item);
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
    secondClick = clock.elapsedMicroseconds;
    _click(page);
    final settleBy = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(settleBy) &&
        !(c.read(strategyProvider).strategyId == opened.id &&
            !c.read(strategyPageSessionProvider).isApplyingPage)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    watching = false;
    final endedOn = c.read(strategyProvider).strategyId == opened.id
        ? openedName
        : c.read(strategyProvider).strategyName;
    final session = c.read(strategyPageSessionProvider);
    await _frames();
    for (final subscription in subscriptions) {
      subscription.close();
    }
    final after = agentsOnFirstPage();
    final lost = before.isNotEmpty && after.isEmpty;
    if (lost) emptied++;
    if (!listEquals(before, after)) {
      (await const LocalLibrary().savePageOnScreen(original)).orThrow();
    }
    final window = switch ((cleared, openedAt)) {
      (final from?, final to?) => to - from,
      _ => null,
    };
    if (window != null) windows.add(window);
    _log(
        'RACE run $run: ${lost ? 'the left page was saved empty' : 'the left page kept its ${before.length} agents'}; '
        'canvas cleared ${cleared == null ? 'never' : '${ms(cleared!)} ms'} after the first click, '
        'second click ${ms(secondClick)} ms after it, '
        '$openedName published ${openedAt == null ? 'never' : '${ms(openedAt!)} ms'} after it; '
        'window ${window == null ? 'not measured' : '${ms(window)} ms'}; '
        'ended on $endedOn page ${session.activePageId}'
        '${session.isApplyingPage ? ' still applying' : ''}');
  }
  windows.sort();
  _log('RACE summary: $runs runs, the left page saved empty $emptied times; '
      'window median ${windows.isEmpty ? '-' : ms(windows[windows.length ~/ 2])} ms, '
      'worst ${windows.isEmpty ? '-' : ms(windows.last)} ms; '
      '$mixedFrames of $framesWatched frames drawn showed the left '
      'strategy\'s agents with the other strategy open');
  if (step['expectEmptied'] case final int expected when expected != emptied) {
    _failedSteps++;
    _log('FAIL raceLeave: the left page was saved empty $emptied times, '
        'expected $expected');
  }
}

Future<void> _drag(
  List<Offset> points, {
  int stepsPerLeg = 30,
  String? shotWhileHeld,
  String? markAtRelease,
  void Function()? firstFrameAfterRelease,
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
  if (markAtRelease != null) _marks[markAtRelease] = Stopwatch()..start();
  binding.handlePointerEvent(
    PointerUpEvent(
      pointer: pointer,
      kind: PointerDeviceKind.mouse,
      position: last,
    ),
  );
  if (firstFrameAfterRelease != null) {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => firstFrameAfterRelease())
      ..scheduleFrame();
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _frames();
}

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
        '${job.assetPublicId}:${_jobPhase(job)}',
    ],
    'syncStatus': c.read(cloudSyncStatusProvider).name,
    'unsaved': c.read(strategySaveStateProvider).isDirty,
    'canLeave': c.read(strategySaveStateProvider).canLeaveSafely,
    'deletedPage': c.read(strategyPageSessionProvider).deletedPage?.name,
    'page': c.read(strategyPageSessionProvider).activePageId,
    'canvasHeld': c.read(strategySaveStateProvider.notifier).canvasHeld,
    'agentsOnPageInHive': _agentsOnPageInHive(c),
  });
}

int? _agentsOnPageInHive(ProviderContainer c) {
  final id = c.read(strategyProvider).strategyId;
  final pageId = c.read(strategyPageSessionProvider).activePageId;
  if (id == null || pageId == null) return null;
  final stored = const LocalLibrary().storedStrategy(id);
  return stored?.pages
      .where((page) => page.id == pageId)
      .firstOrNull
      ?.agentData
      .length;
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

Future<List<String>> _storeLines(Future<List<String>> lines) async {
  try {
    return await lines;
  } on StoreStepFailed catch (failed) {
    failed.problems.forEach(_log);
    throw StateError('the library store step failed');
  }
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
    case 'libraryStore':
      final lines = await _storeLines(
        waitForShadowStore(
          c,
          patience: Duration(seconds: (step['seconds'] ?? 600) as int),
          expected: {...?(step['expect'] as Map<String, dynamic>?)},
          hidden: step['hidden'] == true,
        ),
      );
      lines.forEach(_log);
    case 'libraryFromStore':
      final lines = await _storeLines(
        waitForStoreList(
          c,
          patience: Duration(seconds: (step['seconds'] ?? 600) as int),
          expected: {...?(step['expect'] as Map<String, dynamic>?)},
        ),
      );
      lines.forEach(_log);
      _logListSource('$value');
      (await _storeLines(waitForGridFromStore(c, label: '$value')))
          .forEach(_log);
    case 'gridRowFromStore':
      final mark = step['since'] as String?;
      final row = await _storeLines(
        waitForGridRowFromStore(
          c,
          name: value as String,
          patience: Duration(seconds: (step['seconds'] ?? 10) as int),
        ).then((row) => [row.kind]),
      );
      _log('GRID "$value" ${row.single} drawn from a store row'
          '${switch (_marks[mark]) {
        final since? => ' ${since.elapsedMilliseconds} ms after $mark',
        null => '',
      }}');
    case 'holdListOnHive':
      _log(holdListOnHive(c));
    case 'letListGo':
      _log(letListGo(c));
    case 'expectStoreRefuses':
      storeRefusalsExpected = {...(value as List).cast<String>()};
    case 'watchLibraryText':
      _pictureWatches.add(
        _watchLibraryText(
          value as String,
          gone: step['gone'] == true,
          mark: step['since'] as String,
          seconds: (step['seconds'] ?? 10) as num,
        ),
      );
    case 'holdLibraryStore':
      _log(holdStore(c));
    case 'checkLibraryStore':
      (await _storeLines(checkStoreAgain(c))).forEach(_log);
    case 'slowStoreCommits':
      SlowedEngine.commitDelay = Duration(milliseconds: (value as num).round());
      _log(
          'STORE commits now wait ${SlowedEngine.commitDelay.inMilliseconds} ms');
    case 'actionOps':
      (await _storeLines(
        actionOpsStep(
          c,
          label: '$value',
          expected: {...?(step['expect'] as Map<String, dynamic>?)},
          expectedKinds: {
            ...?(step['expectKinds'] as Map<String, dynamic>?),
          },
        ),
      ))
          .forEach(_log);
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
        markAtRelease: step['mark'] as String?,
      );
    case 'tapKey':
      await _tap(
        _centerOf((w) => _hasKey(w, value as String), nth: nth),
        secondary: step['button'] == 'secondary',
        markAtRelease: step['mark'] as String?,
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
    case 'tapWords':
      await _tap(
        _wordsPoint(value as String, nth: nth),
        secondary: step['button'] == 'secondary',
        times: (step['times'] ?? 1) as int,
        touch: step['touch'] == true,
      );
    case 'hoverWords':
      await _hover(_wordsPoint(value as String, nth: nth));
    case 'dragWords':
      final from = _wordsPoint(value as String, nth: nth);
      await _drag([from, from + _point(step, 'by')]);
    case 'tapDoor':
      await _tap(_doorPoint(value as String));
    case 'hoverDoor':
      await _hover(_doorPoint(value as String));
    case 'dragAt':
      await _drag(
        [_point(step, name), _point(step, name, 2)],
        markAtRelease: step['mark'] as String?,
      );
    case 'path':
      final expectOpPending = step['opStillPending'] == true;
      String? firstFrame;
      await _drag([
        for (final p in (value as List).cast<List>())
          Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
      ],
          stepsPerLeg: 6,
          shotWhileHeld: step['held'] as String?,
          firstFrameAfterRelease: switch (step['firstFrame']) {
            final String label => () {
                _log(
                  'FIRST FRAME after releasing $label: drawings on screen '
                  '${c.read(drawingProvider).elements.length}; '
                  '${actionOpsInFlight(c)}',
                );
                firstFrame = opStillPendingProblem(c) ?? '';
              },
            _ => null,
          });
      if (expectOpPending) {
        switch (firstFrame) {
          case null:
            throw StateError('no frame was seen after the release');
          case final String problem when problem.isNotEmpty:
            throw StateError(problem);
        }
      }
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
    case 'panScroll':
      final v = (value as List).cast<num>();
      await _panScroll(
        Offset(v[0].toDouble(), v[1].toDouble()),
        v[2].toDouble(),
        Duration(milliseconds: v[3].toInt()),
      );
    case 'key':
      await _expectKeyFocus();
      if (step['mark'] case final String mark) {
        _marks[mark] = Stopwatch()..start();
      }
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
      final type = AgentType.values.byName((step['agent'] ?? 'jett') as String);
      final isAlly = step['enemy'] != true;
      final cone = step['cone'] as String?;
      agents.addAgent(
        cone == null
            ? PlacedAgent(
                id: id,
                type: type,
                position: const Offset(500, 500),
                isAlly: isAlly,
              )
            : PlacedViewConeAgent(
                id: id,
                type: type,
                position: const Offset(500, 500),
                presetType: UtilityType.values.byName(cone),
                rotation: _radians(step['facing']),
                length: ((step['length'] ?? 0) as num).toDouble(),
                isAlly: isAlly,
              ),
      );
      await _place(id, _point(step, 'at'), (p) => agents.updatePosition(p, id));
    case 'fillPage':
      int onPage() =>
          c.read(agentProvider).length +
          c.read(abilityProvider).length +
          c.read(drawingProvider).elements.length +
          c.read(textProvider).length +
          c.read(placedImageProvider).images.length +
          c.read(utilityProvider).length;
      final from = onPage();
      final target = (value as num).toInt();
      final agents = c.read(agentProvider.notifier);
      final texts = c.read(textProvider.notifier);
      const types = [
        AgentType.jett,
        AgentType.sova,
        AgentType.sage,
        AgentType.omen,
      ];
      c.read(actionProvider.notifier).performTransaction(
        groups: const [],
        mutation: () {
          for (var n = from; n < target; n++) {
            final at = Offset(60.0 + (n % 40) * 22, 60.0 + (n ~/ 40) * 22);
            if (n.isEven) {
              agents.addAgent(PlacedAgent(
                id: 'fill-$n',
                type: types[(n ~/ 2) % types.length],
                position: at,
              ));
            } else {
              texts.addText(PlacedText(
                id: 'fill-$n',
                position: at,
                sizeVersion: worldSizedMediaVersion,
              )..text = 'Fill $n');
            }
          }
        },
      );
      await _frames(2);
      _log('FILL the page went from $from to ${onPage()} items');
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
          rotation: _radians(step['facing']),
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
          customColorValue: type == UtilityType.spike ? null : 0xFF22C55E,
          customOpacityPercent: type == UtilityType.spike ? null : 30,
          mapDoor: step['door'] as String?,
          isZone: step['zone'] == true,
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
      await _drag(
        [
          from,
          step['toWorld'] == null
              ? from + _point(step, 'by')
              : _canvasPointOnScreen(_point(step, 'toWorld')),
        ],
        stepsPerLeg: ((step['steps'] ?? 30) as num).toInt(),
        shotWhileHeld: step['held'] as String?,
      );
    case 'hoverAgent':
      final id = value as String;
      await _hover(
        _centerOf((w) => w is AgentWidget && (w.id == id || w.lineUpId == id)),
      );
    case 'signOut':
      final signingOut = c.read(guardedSignOutRequestProvider)(
        appNavigatorKey.currentContext!,
      );
      bool confirm(Widget w) => _hasKey(w, 'sign-out-confirm');
      await _waitFor(() => _countOf(confirm) > 0, 30);
      await _tap(_centerOf(confirm));
      if (!await signingOut) throw StateError('the sign-out was not done');
      await _waitFor(() => c.read(authProvider).user == null, 60);
    case 'signIn':
      final second = value == 'second';
      final email = second
          ? Platform.environment['ICARUS_DRIVE_EMAIL_2']!
          : Platform.environment['ICARUS_DRIVE_EMAIL']!;
      final signedIn = Supabase.instance.client.auth.currentUser?.email;
      if (signedIn != null && signedIn != email) {
        throw StateError('signed in as $signedIn, not $email');
      }
      if (signedIn == null) {
        final error =
            await c.read(authProvider.notifier).signInWithEmailPassword(
                  email: email,
                  password: second
                      ? Platform.environment['ICARUS_DRIVE_PASSWORD_2']!
                      : Platform.environment['ICARUS_DRIVE_PASSWORD']!,
                );
        if (error != null) throw StateError(error);
      }
      await _waitFor(() => c.read(authProvider).isConvexUserReady, 60);
    case 'refreshSession':
      await Supabase.instance.client.auth.refreshSession();
    case 'reconnect':
      await ConvexClient.instance.reconnect();
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
    case 'mapThenOpen':
      await _mapThenOpen(step);
    case 'openStoredCloudStrategy':
      unawaited(
        Navigator.of(appNavigatorKey.currentContext!).push(
          StrategyView.route(
            initialStrategyId: storedCloudStrategy(c),
            initialStrategySource: StrategySource.cloud,
          ),
        ),
      );
    case 'breakConvexSignIn':
      _log(await breakConvexSignIn());
    case 'restoreConvexSignIn':
      await c
          .read(authProvider.notifier)
          .reinitializeConvexAuth(source: 'driver');
      _log('CLOUDSTORE the app set up its Convex sign-in again');
    case 'holdSender':
      _log(holdSender(c));
    case 'releaseSender':
      _log(releaseSender(c));
    case 'storeMove':
      final by = step['by'] as List;
      _log(
        await storeMove(
          c,
          value as String,
          ((by[0] as num).toDouble(), (by[1] as num).toDouble()),
          startingWith: step['startingWith'] == true,
          merge: step['merge'] == true,
        ),
      );
    case 'storeMayLag':
      final lag = (row: value as String, why: step['why'] as String);
      _cloudStore.lagging.add(lag);
      _log(
        'CLOUDSTORE item ${lag.row} may be at an older revision in the store '
        'than on the server at the end: ${lag.why}',
      );
    case 'storeExpect':
      final expected = await expectStrategy(
        c,
        value as Object,
        Duration(seconds: ((step['within'] ?? 60) as num).toInt()),
      );
      _cloudStore.expected.add(expected);
      _log(
        'CLOUDSTORE the store holds ${expected.id} "${expected.name}", and '
        'must still hold it, equal to the server\'s copy, at the end',
      );
    case 'storeAdd':
      final at = step['at'] as List;
      _log(
        await storeAdd(
          c,
          value as String,
          kind: step['kind'] as String,
          at: ((at[0] as num).toDouble(), (at[1] as num).toDouble()),
        ),
      );
    case 'storeDelete':
      _log(await storeDelete(c, value as String));
    case 'storeSetField':
      _log(
        await storeSetField(
          c,
          value as String,
          step['field'] as String,
          step['to'],
        ),
      );
    case 'waitStoreRefusedLate':
      _log(
        await waitStoreRefusedLate(
          c,
          Duration(seconds: (value as num).toInt()),
        ),
      );
    case 'storeAddPage':
      _log(await storeAddPage(c));
    case 'addPage':
      await c.read(strategyProvider.notifier).addPage();
    case 'storeDeletePage':
      if (value is! int || value < 0) {
        throw StateError(
          'storeDeletePage takes a page number counting from 0, not $value',
        );
      }
      _log(await storeDeletePage(c, value));
    case 'setMemberRole':
      _log(await setMemberRole(c, value as String));
    case 'waitStoreSent':
      _log(
        await waitStoreSent(
          c,
          Duration(seconds: (value as num).toInt()),
          landedMayWait: step['landed'] == 'may wait',
        ),
      );
    case 'expectStoreNeedsYou':
      (await storeNeedsYou(c)).forEach(_log);
    case 'storeUseCloud':
      _log(await storeUseCloud(c, value as String));
    case 'storeSyncState':
      (await storeSyncStates(c)).forEach(_log);
    case 'waitStoreHeld':
      _log(
        await waitStoreHeld(c, Duration(seconds: (value as num).toInt())),
      );
    case 'killNow':
      _log('KILLED by the script');
      await _flush();
      exit(9);
    case 'expectPageListRefusedNaming':
      _log(await pageListRefusal(c, value as String));
    case 'expectBatchRefusedNaming':
      _log(
        await batchRefusal(
          c,
          value as String,
          readsAccountMismatch: step['readsAccountMismatch'] as bool,
        ),
      );
    case 'sendUncheckedDelete':
      _log(
        await uncheckedDelete(
          c,
          value as String,
          basisAgeMs: step['basisAgeMs'] as int,
          expectRefused: step['expectRefused'] as bool,
        ),
      );
    case 'expectStoredPayloadVersion':
      _log(
        await storedPayloadVersion(
          c,
          value as String,
          (step['version'] as num).toInt(),
        ),
      );
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
    case 'openReplay':
      final listing =
          await c.read(replayLibraryProvider.notifier).import(value as String);
      c.read(libraryNavigationProvider).showReplays();
      openReplayListing(appNavigatorKey.currentContext!, listing);
    case 'seekReplay':
      (_elementOf((widget) => widget is ReplayDock).widget as ReplayDock)
          .playback
        ..pause()
        ..seek(value as int);
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
    case 'raceLeave':
      await _raceLeave(step);
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
      await _shot(value as String);
    case 'framesStart':
      _frameTimings.clear();
      forgetNoticeFrames();
      SchedulerBinding.instance.addTimingsCallback(_frameTimings.addAll);
    case 'framesLog':
      final counted = _frameTimings.length;
      final reported = DateTime.now().add(const Duration(seconds: 2));
      while (noticeFramesUntimed(_frameTimings) &&
          DateTime.now().isBefore(reported)) {
        await _frames(1);
      }
      SchedulerBinding.instance.removeTimingsCallback(_frameTimings.addAll);
      final timings = _frameTimings.take(counted);
      String times(Iterable<Duration> durations) {
        final ms = [for (final d in durations) d.inMicroseconds / 1000]..sort();
        if (ms.isEmpty) return 'none';
        String at(double share) =>
            ms[((ms.length - 1) * share).round()].toStringAsFixed(2);
        return 'p50 ${at(.5)} p90 ${at(.9)} p99 ${at(.99)} worst ${at(1)}';
      }
      _log('FRAMES $value n=${timings.length} '
          'build ${times(timings.map((t) => t.buildDuration))} '
          'raster ${times(timings.map((t) => t.rasterDuration))}');
      _log(
          'FRAMES $value after a list notice ${switch (noticeFramesLine(_frameTimings)) {
        '' => 'none',
        final line => line,
      }}');
    case 'burst':
      // Its failure is held until the shots are in, then fails this step.
      final during = step['during'] == null
          ? null
          : _run((step['during'] as Map).cast<String, dynamic>())
              .then<Object?>((_) => null, onError: (Object error) => error);
      for (var i = 0; i < ((step['count'] ?? 10) as int); i++) {
        final file = '$value-${i.toString().padLeft(3, '0')}.png';
        final transition = await _shot(file);
        _log('BURST $file ${transition.phase.name} '
            '${transition.progress.toStringAsFixed(3)}');
        await Future<void>.delayed(
          Duration(milliseconds: (step['every'] ?? 100) as int),
        );
      }
      if (await during case final Object failure) throw failure;
    case 'slowMotion':
      timeDilation = (value as num).toDouble();
    case 'logLineups' when step['frames'] is int:
      final frames = step['frames'] as int;
      var frame = 0;
      void logFrame(Duration _) {
        final links = [
          for (final link in c.read(lineUpProvider).links) link.id,
        ];
        _log('LINEUPS $value frame ${frame++} $links');
        if (frame >= frames) return;
        SchedulerBinding.instance
          ..addPostFrameCallback(logFrame)
          ..scheduleFrame();
      }

      SchedulerBinding.instance
        ..addPostFrameCallback(logFrame)
        ..scheduleFrame();
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
    case 'logLibrary':
      _logLibrary('$value', libraryOnScreen());
    case 'logPagesBar':
      _logPagesBar('$value', pagesBarOnScreen());
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
                '${u.customLength == null ? '' : ' ${u.customLength!.toStringAsFixed(1)}x${u.customWidth!.toStringAsFixed(1)}'}'
                '${u.isZone ? ' zone' : ''}',
        ]} '
        'lineups=${c.read(lineUpProvider).graph.links.length} '
        'selected=${c.read(canvasSelectionProvider).length} '
        'tool=${c.read(interactionStateProvider).name} '
        'agentSize=${c.read(strategySettingsProvider).agentSize} '
        'abilitySize=${c.read(strategySettingsProvider).abilitySize}',
      );
    case 'expectOpened':
      if (!listEquals(_openedLinks, (value as List).cast<String>())) {
        throw StateError('opened $_openedLinks, expected $value');
      }
    case 'expectEditing':
      if (_editing() != value) {
        throw StateError(
            '${_editing() ? 'a' : 'no'} text field has the keyboard');
      }
    case 'logTexts':
      _log('TEXTBOXES $value ${jsonEncode([
            for (final text in c.read(textProvider))
              {
                'id': text.id,
                'x': text.position.dx,
                'y': text.position.dy,
                'width': text.size,
                'text': text.text,
              },
          ])}');
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
    case 'expectOnMapLine':
      final id = _itemId(value as String);
      final map = c.read(mapProvider).currentMap;
      final agents = c.read(agentProvider).where((agent) => agent.id == id);
      final abilities = c.read(abilityProvider).where((a) => a.id == id);
      final dot = agents.isNotEmpty
          ? agents.single.position +
              CoordinateSystem.virtualToWorld(storedAgentAnchor)
          : abilities.single.position +
              CoordinateSystem.virtualToWorld(
                storedAbilityAnchor(
                  ability: abilities.single.data.abilityData!,
                  mapScale: Maps.mapScale[map] ?? 1,
                ),
              );
      final lines = await c.read(mapLinesProvider(map).future);
      final away = (lines.nearest(dot, double.infinity)! - dot).distance;
      _log('ON-LINE $id dot=${dot.dx.toStringAsFixed(2)},'
          '${dot.dy.toStringAsFixed(2)} away=${away.toStringAsFixed(3)}');
      if (away > 0.5) throw StateError('$id is $away off the nearest line');
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
      _log(
          'IN-VIEW view=${view.left},${view.top},${view.right},${view.bottom} ${{
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
        if (step['middles'] == true) {
          if (!view.contains(drawn.center)) {
            throw StateError('$id has its middle out of view: $drawn');
          }
          continue;
        }
        if (view.intersect(drawn) != drawn) {
          throw StateError('$id is out of view: $drawn');
        }
      }
    case 'sendRow':
      final id = value as String;
      final kind = step['kind'] as String;
      final pageId = c.read(strategyPageSessionProvider).activePageId!;
      final payload = {
        ...cloudElementPayload(kind: kind, data: {
          ...(step['data'] as Map).cast<String, dynamic>(),
          'id': id,
          'elementType': kind,
        }),
        if (step['version'] case final num version) 'payloadVersion': version,
      };
      final existing = c
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.elements
          .where((row) => row.publicId == id && !row.deleted)
          .firstOrNull;
      final answers = await c.read(convexStrategyRepositoryProvider).applyBatch(
        strategyPublicId: c.read(strategyProvider).strategyId!,
        clientId: 'drive-another-build-$id',
        ops: [
          if (existing == null)
            ElementAddOp(
              opId: const Uuid().v4(),
              elementPublicId: id,
              pagePublicId: pageId,
              payload: payload,
              sortIndex: 1000,
            )
          else
            ElementPatchOp(
              opId: const Uuid().v4(),
              elementPublicId: id,
              pagePublicId: pageId,
              expectedElementRevision: existing.revision,
              payload: payload,
            ),
        ],
      );
      if (!answers.single.isAck) {
        throw StateError('the server refused $value: ${answers.single}');
      }
    case 'expectRow':
      final id = value as String;
      final copy = step['copy'] == true;
      final version = step['version'] as num?;
      RemoteElement? row() => c
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.elements
          .where(
            (row) =>
                !row.deleted &&
                (copy
                    ? row.publicId != id && pageCopyRoot(row.publicId) == id
                    : row.publicId == id),
          )
          .firstOrNull;
      bool held() =>
          row() != null &&
          (version == null || row()!.payload['payloadVersion'] == version);
      final gone = step['gone'] == true;
      try {
        await _waitFor(() => held() != gone, 30);
      } on TimeoutException {
        throw StateError(
          gone
              ? 'the server still holds $value'
              : 'the server does not hold $value as asked: ${row()?.payload}',
        );
      }
      _log('ROW $value ${copy ? 'copy ' : ''}${row()?.publicId} '
          'version=${row()?.payload['payloadVersion']} '
          '${held() ? 'held' : 'gone'}');
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
    case 'expectTag':
      final id = _itemId(value as String);
      final wanted = step['color'] as String?;
      // One entry while the item is on the page; an item that's gone has no
      // tag, which isn't a gray one.
      List<int?> tags() => [
            for (final text in c.read(textProvider))
              if (text.id == id) text.tagColorValue,
            for (final image in c.read(placedImageProvider).images)
              if (image.id == id) image.tagColorValue,
          ];
      String name(int? color) => color == null
          ? 'gray'
          : (color & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
      try {
        await _waitFor(
          () => tags().isNotEmpty && name(tags().first) == (wanted ?? 'gray'),
          (step['seconds'] ?? 0) as num,
        );
      } on TimeoutException {
        throw StateError(
          tags().isEmpty
              ? '$value is not on the page'
              : "$value's tag is ${name(tags().first)}, not ${wanted ?? 'gray'}",
        );
      }
    case 'expectOpacity':
      int? opacity() => c
          .read(utilityProvider)
          .where((utility) => utility.id == value)
          .firstOrNull
          ?.customOpacityPercent;
      try {
        await _waitFor(
          () => opacity() == step['percent'],
          (step['seconds'] ?? 0) as num,
        );
      } on TimeoutException {
        throw StateError('$value is at ${opacity()}%, not ${step['percent']}%');
      }
      _log('OPACITY $value ${opacity()}%');
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
    case 'outboxWrites':
      if (value == true) {
        await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
      } else {
        await Hive.box<dynamic>(HiveBoxNames.strategyOutboxBox).close();
      }
    case 'dropOpenPage':
      final strategy = const LocalLibrary()
          .storedStrategy(c.read(strategyProvider).strategyId!)!;
      final pageId = c.read(strategyPageSessionProvider).activePageId;
      (await const LocalLibrary().changePages(
        strategy.copyWith(
          pages: [
            for (final page in strategy.pages)
              if (page.id != pageId) page,
          ],
        ),
      ))
          .orThrow();
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

Future<void> _watchLibraryText(
  String text, {
  required bool gone,
  required String mark,
  required num seconds,
}) async {
  bool settled() =>
      libraryOnScreen().any((line) => line.contains('"$text"')) != gone;
  void fail(String why) {
    _failedSteps++;
    _log('FAIL "$text" $why');
  }

  if (settled()) {
    fail('was already ${gone ? 'gone from' : 'on'} the library screen '
        'before $mark');
    return;
  }
  final before = _marks[mark];
  final markBy = DateTime.now().add(const Duration(minutes: 2));
  while (identical(_marks[mark], before) && DateTime.now().isBefore(markBy)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  final since = _marks[mark];
  if (since == null || identical(since, before)) {
    fail('was watched for, but $mark never happened');
    return;
  }
  final patience = Duration(milliseconds: (seconds * 1000).round());
  while (since.elapsed < patience && !settled()) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  if (!settled()) {
    fail('never ${gone ? 'left' : 'reached'} the library on screen within '
        '$seconds s of $mark');
    return;
  }
  _log('TIMED $mark "$text" ${gone ? 'gone from' : 'on'} the library screen '
      '${since.elapsedMilliseconds} ms after the action');
}

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
      'JOB $tag ${job.assetPublicId} ${_jobPhase(job)} ${job.mimeType}',
    );
  }
}

String _jobPhase(CloudMediaUploadJob job) => switch (job.phase) {
      MediaWaitingToUpload() => 'waiting',
      MediaUploaded() => 'uploaded',
      MediaUploadFailed(:final attempts, :final why) =>
        'failed attempts=$attempts why=$why',
    };

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
