import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/replay/replay_cone_cuts.dart';
import 'package:icarus/replay/replay_cone_worker.dart';
import 'package:icarus/replay/replay_decoder.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:icarus/replay/replay_loader.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/replay/replay_canvas.dart';
import 'package:icarus/widgets/replay/replay_dock.dart';
import 'package:icarus/widgets/replay/replay_match_card.dart';
import 'package:icarus/widgets/replay/replay_roster.dart';
import 'package:icarus/widgets/window_chrome.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Watches one Valorant replay on the Icarus map. The map, the players and
/// their utility are the editor's own widgets, so whatever is on screen can
/// be captured into a strategy as it stands.
class ReplayView extends ConsumerStatefulWidget {
  const ReplayView({super.key, required this.file, required this.probe});

  final ReplayFile file;
  final ReplayProbe probe;

  static Route<void> route({
    required ReplayFile file,
    required ReplayProbe probe,
  }) =>
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => ReplayView(file: file, probe: probe),
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      );

  @override
  ConsumerState<ReplayView> createState() => _ReplayViewState();
}

class _ReplayViewState extends ConsumerState<ReplayView>
    with SingleTickerProviderStateMixin {
  late final ReplayLoader _loader;
  late final Ticker _ticker;
  Timer? _progressTimer;

  ReplayPlayback? _playback;
  ProviderSubscription<AsyncValue<SvgHeightRuntime?>>? _heightRuntime;
  SvgHeightVisibility? _heightModel;
  SvgHeightRuntime? _heightRuntimeValue;

  /// Cuts view cones off the UI thread once the map's models are in.
  ReplayConeCuts? _coneCuts;
  var _startingConeCuts = false;
  ReplayDecodeException? _error;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _loader = ReplayLoader(
      files: ref.read(replayFilesProvider),
      file: widget.file,
      probe: widget.probe,
    );
    final map = ReplayMapProjection.forMapPath(widget.probe.mapPath)?.map;
    if (map != null) {
      // Held for the screen's life: the provider frees the model otherwise.
      _heightRuntime = ref.listenManual(
        svgHeightRuntimeProvider(map),
        (_, runtime) => _applyHeightModel(runtime.valueOrNull),
        fireImmediately: true,
      );
    }
    // Progress lives in native memory; repaint the bar while decoding.
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => setState(() {}),
    );
    _open();
  }

  Future<void> _open() async {
    try {
      final projection = ReplayMapProjection.forMapPath(widget.probe.mapPath);
      if (projection == null) {
        throw const ReplayDecodeException(
          'unsupportedMap',
          "This replay's map isn't in Icarus yet.",
        );
      }
      final document = await _loader.load();
      if (!mounted) return;
      final perspective = await _defaultPerspective(document);
      if (!mounted) return;
      final playback = ReplayPlayback(
        document: document,
        projection: projection,
        perspective: perspective,
      )..addListener(_syncMapSide);
      if (_heightModel != null) playback.heightModel = _heightModel;
      setState(() => _playback = playback);
      unawaited(_startConeCuts());
      claimEditorState();
      _ticker.start();
    } on ReplayDecodeException catch (error) {
      if (mounted && !error.isCancelled) setState(() => _error = error);
    } on FormatException catch (error) {
      _fail(ReplayDecodeException('corrupt', error.message));
    } catch (error) {
      // Whatever else went wrong, the screen must not sit on "Reading".
      _fail(ReplayDecodeException('io', '$error'));
    } finally {
      _progressTimer?.cancel();
    }
  }

  /// Cones stand on the level the replay says each player is on, once the
  /// map's height model is in.
  void _applyHeightModel(SvgHeightRuntime? runtime) {
    final model = runtime?.model(true);
    if (model == null || identical(model, _heightModel)) return;
    _heightModel = model;
    _heightRuntimeValue = runtime;
    _playback?.heightModel = model;
    unawaited(_startConeCuts());
  }

  /// Starts cutting view cones on a worker once both the replay and the
  /// map's height models are in. Until then each cone cuts its own.
  Future<void> _startConeCuts() async {
    final playback = _playback;
    final runtime = _heightRuntimeValue;
    if (playback == null ||
        runtime == null ||
        _coneCuts != null ||
        _startingConeCuts) {
      return;
    }
    final registration = svgHeightRegistrationFor(runtime.map);
    if (registration == null) return;
    _startingConeCuts = true;
    try {
      final dependencies = ref.read(svgHeightRuntimeDependenciesProvider);
      final worker = await ReplayConeWorker.start(
        attackModel: await dependencies.loadModel(registration, true),
        defenseModel: await dependencies.loadModel(registration, false),
      );
      if (!mounted) {
        worker.dispose();
        return;
      }
      _coneCuts = playback.coneCuts = ReplayConeCuts(
        worker: worker,
        map: runtime.map,
        attackModel: runtime.model(true),
        defenseModel: runtime.model(false),
        coneLength: ReplayFrameBuilder.coneLength,
        apertureDegrees: UtilityData.getViewConeAngle(UtilityType.viewCone180),
        onCut: playback.coneCutArrived,
      );
    } catch (_) {
      // Without the worker each cone cuts its own, as in the editor.
    } finally {
      _startingConeCuts = false;
    }
  }

  void _fail(ReplayDecodeException error) {
    if (mounted) setState(() => _error = error);
  }

  /// The team of whoever played this match on this machine, else Red.
  Future<ReplayTeam> _defaultPerspective(ReplayDocument document) async {
    Set<String> local;
    try {
      local = await ref.read(replayFilesProvider).localSubjects();
    } on FileSystemException {
      local = const {};
    }
    for (final player in document.players) {
      final team = player.team;
      if (team != null && local.contains(player.subject.toLowerCase())) {
        return team;
      }
    }
    return ReplayTeam.red;
  }

  void _onTick(Duration elapsed) {
    final delta = elapsed - _lastTick;
    _lastTick = elapsed;
    _playback?.advance(delta);
  }

  /// The editor's widgets this screen draws with read their map, side and
  /// marker settings from the editor's providers. Point them at this replay
  /// and at the settings a captured strategy starts with. Called on opening
  /// and on coming back from the editor, which leaves its own state behind.
  void claimEditorState() {
    final playback = _playback;
    if (playback == null) return;
    final preferences = ref.read(appPreferencesProvider);
    ref.read(strategySettingsProvider.notifier).fromHive(
          StrategySettings(
            agentSize: preferences.defaultAgentSizeForNewStrategies,
            abilitySize: preferences.defaultAbilitySizeForNewStrategies,
            useNeutralTeamColors:
                preferences.defaultNeutralTeamColorsForNewStrategies,
          ),
        );
    _syncMapSide();
  }

  /// The side follows the perspective team round by round.
  void _syncMapSide() {
    final playback = _playback;
    if (playback == null) return;
    final map = playback.frames.projection.map;
    final isAttack = playback.frame.isAttack;
    final current = ref.read(mapProvider);
    if (current.currentMap == map && current.isAttack == isAttack) return;
    ref.read(mapProvider.notifier).fromHive(map, isAttack);
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _heightRuntime?.close();
    _loader.cancel();
    _ticker.dispose();
    _coneCuts?.dispose();
    _playback
      ?..removeListener(_syncMapSide)
      ..dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final playback = _playback;
    if (playback == null || event is KeyUpEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        if (event is KeyRepeatEvent) return KeyEventResult.handled;
        playback.togglePlaying();
      case LogicalKeyboardKey.arrowLeft:
        playback.seek(playback.timeMs - 5000);
      case LogicalKeyboardKey.arrowRight:
        playback.seek(playback.timeMs + 5000);
      case LogicalKeyboardKey.arrowUp:
        playback.previousRound();
      case LogicalKeyboardKey.arrowDown:
        playback.nextRound();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final playback = _playback;
    final map = ReplayMapProjection.forMapPath(widget.probe.mapPath)?.map;
    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            _ReplayStrip(map: map, probe: widget.probe),
            Expanded(
              child: playback != null
                  ? _ReplayBench(
                      playback: playback,
                      map: map!,
                      onReturnFromEditor: claimEditorState,
                    )
                  : _ReplayLoading(
                      progress: _loader.progress,
                      error: _error,
                      onBack: () => Navigator.pop(context),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplayStrip extends StatelessWidget {
  const _ReplayStrip({required this.map, required this.probe});

  final MapValue? map;
  final ReplayProbe probe;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return AppWindowStrip(
      child: Stack(
        children: [
          Row(
            children: [
              const SizedBox(width: 6),
              ShadTooltip(
                builder: (context) => const Text('Replays'),
                child: ShadIconButton.ghost(
                  width: 28,
                  height: 28,
                  foregroundColor: theme.mutedForeground,
                  hoverForegroundColor: theme.foreground,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(LucideIcons.house300, size: 18),
                ),
              ),
              const IcarusWordmark(),
              const Expanded(child: WindowDragArea(child: SizedBox.expand())),
            ],
          ),
          Center(
            child: IgnorePointer(
              child: Text(
                [
                  if (map != null) replayMapName(map!),
                  MaterialLocalizations.of(context).formatMediumDate(
                    probe.recordedAt ?? DateTime.now(),
                  ),
                ].join(' · '),
                // DESIGN.md body role, the size of the editor's title.
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: theme.foreground,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String replayMapName(MapValue map) {
  final name = Maps.mapNames[map]!;
  return name[0].toUpperCase() + name.substring(1);
}

/// The canvas with its three floating panels, laid out like the editor:
/// match and actions top-left, roster on the right, timeline along the
/// bottom.
class _ReplayBench extends StatelessWidget {
  const _ReplayBench({
    required this.playback,
    required this.map,
    required this.onReturnFromEditor,
  });

  final ReplayPlayback playback;
  final MapValue map;
  final VoidCallback onReturnFromEditor;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: ReplayCanvas(
              playback: playback,
              map: map,
              reservedRight: ReplayRoster.width + 16,
            ),
          ),
        ),
        Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: ReplayMatchCard(
              playback: playback,
              map: map,
              onReturnFromEditor: onReturnFromEditor,
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          bottom: 8,
          child: ReplayRoster(playback: playback),
        ),
        Positioned(
          left: 8,
          right: ReplayRoster.width + 16,
          bottom: 8,
          child: Center(child: ReplayDock(playback: playback)),
        ),
      ],
    );
  }
}

class _ReplayLoading extends StatelessWidget {
  const _ReplayLoading({
    required this.progress,
    required this.error,
    required this.onBack,
  });

  final double progress;
  final ReplayDecodeException? error;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final failure = error;
    return Center(
      child: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              failure == null ? 'Reading replay' : "Couldn't open this replay",
              style: theme.textTheme.p,
            ),
            const SizedBox(height: 12),
            if (failure == null)
              ShadProgress(value: progress <= 0 ? null : progress)
            else ...[
              Text(failure.message, style: theme.textTheme.muted),
              const SizedBox(height: 16),
              ShadButton.secondary(
                onPressed: onBack,
                child: const Text('Back to replays'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
