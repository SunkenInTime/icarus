import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/replay_provider.dart';
import 'package:icarus/replay/replay_ability_audit.dart';
import 'package:icarus/replay/replay_track.dart';
import 'package:icarus/widgets/replay/replay_map_canvas.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ReplayView extends ConsumerStatefulWidget {
  const ReplayView({super.key});

  @override
  ConsumerState<ReplayView> createState() => _ReplayViewState();
}

class _ReplayViewState extends ConsumerState<ReplayView> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) {
      ref.read(replayProvider.notifier).advanceBy(33);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(replayProvider).hasTrack) return;
      ref.read(replayProvider.notifier).loadDemoTrack();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final replayState = ref.watch(replayProvider);
    final replayNotifier = ref.read(replayProvider.notifier);
    final track = replayState.track;
    final importEnabled = !replayState.isImportingVrf;

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: 15,
              top: 15,
              bottom: 10,
              right: 15,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    ShadIconButton.ghost(
                      foregroundColor: Colors.white,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.home),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Replay Viewer',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 10),
                    _ReplayStatusPill(
                      label: track == null
                          ? 'No track loaded'
                          : Maps.mapNames[track.map] ?? 'Unknown map',
                    ),
                  ],
                ),
                Row(
                  children: [
                    ShadButton.secondary(
                      enabled: importEnabled,
                      leading: const Icon(Icons.science_outlined),
                      onPressed: replayNotifier.loadDemoTrack,
                      child: const Text('Demo Track'),
                    ),
                    const SizedBox(width: 10),
                    ShadButton(
                      enabled: importEnabled,
                      leading: Icon(
                        replayState.isImportingVrf
                            ? Icons.hourglass_top
                            : Icons.video_file_outlined,
                      ),
                      onPressed: replayNotifier.loadVrfFromFilePicker,
                      child: Text(
                        replayState.isImportingVrf
                            ? 'Importing VRF'
                            : 'Load VRF',
                      ),
                    ),
                    const SizedBox(width: 10),
                    ShadButton.secondary(
                      enabled: importEnabled,
                      leading: const Icon(Icons.file_open),
                      onPressed: replayNotifier.loadFromFilePicker,
                      child: const Text('Load Track JSON'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                const Expanded(child: ReplayMapCanvas()),
                SizedBox(
                  width: Settings.sideBarReservedWidth,
                  child: _ReplaySidePanel(state: replayState),
                ),
              ],
            ),
          ),
          _ReplayTransportBar(state: replayState),
        ],
      ),
    );
  }
}

class _ReplayStatusPill extends StatelessWidget {
  const _ReplayStatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xffa1a1aa),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ReplayTransportBar extends ConsumerWidget {
  const _ReplayTransportBar({required this.state});

  final ReplayState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(replayProvider.notifier);
    final duration = state.durationMs;
    final current = state.currentTimeMs.clamp(0, duration);

    return Container(
      height: 82,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.background,
        border: Border(
          top: BorderSide(color: Settings.tacticalVioletTheme.border),
        ),
      ),
      child: Row(
        children: [
          ShadIconButton.secondary(
            enabled: state.hasTrack,
            onPressed: notifier.togglePlayback,
            icon: Icon(state.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 88,
            child: Text(
              _formatMs(current),
              style: const TextStyle(
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Slider(
              value: duration == 0 ? 0 : current.toDouble(),
              min: 0,
              max: duration == 0 ? 1 : duration.toDouble(),
              onChanged: state.hasTrack
                  ? (value) => notifier.seek(value.round())
                  : null,
            ),
          ),
          SizedBox(
            width: 88,
            child: Text(
              _formatMs(duration),
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Color(0xffa1a1aa),
                fontFeatures: [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 18),
          SegmentedButton<double>(
            segments: const [
              ButtonSegment(value: 0.5, label: Text('0.5x')),
              ButtonSegment(value: 1.0, label: Text('1x')),
              ButtonSegment(value: 2.0, label: Text('2x')),
              ButtonSegment(value: 4.0, label: Text('4x')),
            ],
            selected: {state.playbackSpeed},
            showSelectedIcon: false,
            onSelectionChanged: state.hasTrack
                ? (selection) => notifier.setPlaybackSpeed(selection.first)
                : null,
          ),
        ],
      ),
    );
  }
}

class _ReplaySidePanel extends ConsumerWidget {
  const _ReplaySidePanel({required this.state});

  final ReplayState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = state.track;
    final notifier = ref.read(replayProvider.notifier);

    return Container(
      color: Settings.sideBarColor,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Container(
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Settings.tacticalVioletTheme.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Track',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              _MetadataRow(
                label: 'Source',
                value: state.lastLoadedPath ?? track?.sourceLabel ?? 'None',
              ),
              _MetadataRow(
                label: 'Players',
                value: '${track?.players.length ?? 0}',
              ),
              _MetadataRow(
                label: 'Duration',
                value: _formatMs(state.durationMs),
              ),
              if (track?.notes != null && track!.notes!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  track.notes!,
                  style: const TextStyle(
                    color: Color(0xffa1a1aa),
                    height: 1.35,
                    fontSize: 12,
                  ),
                ),
              ],
              if (state.errorMessage != null) ...[
                const SizedBox(height: 12),
                SelectionArea(
                  child: Text(
                    state.errorMessage!,
                    style: TextStyle(
                      color: Settings.tacticalVioletTheme.destructive,
                      height: 1.35,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              if (state.importStatusMessage != null) ...[
                const SizedBox(height: 12),
                if (state.isImportingVrf) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      color: Settings.tacticalVioletTheme.primary,
                      backgroundColor: Settings.tacticalVioletTheme.border,
                      semanticsLabel: 'Replay import progress',
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  state.importStatusMessage!,
                  style: const TextStyle(
                    color: Color(0xffa1a1aa),
                    height: 1.35,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              if (track != null) ...[
                _ReplayAbilityEventControls(state: state),
                const SizedBox(height: 12),
                if (state.abilityAuditEnabled)
                  _ReplayAbilityAuditPanel(state: state)
                else ...[
                  _ReplayReviewWindowControls(state: state),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 132,
                    child: _ReplayTimelineGraph(state: state),
                  ),
                ],
                const SizedBox(height: 14),
              ],
              Text(
                _hasCandidateEntities(track) ? 'Entities' : 'Players',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: track == null
                    ? const Center(
                        child: Text(
                          'No player tracks yet.',
                          style: TextStyle(color: Color(0xffa1a1aa)),
                        ),
                      )
                    : ListView.separated(
                        itemCount: track.players.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final player = track.players[index];
                          final visible = state.visiblePlayerIds.contains(
                            player.id,
                          );
                          return _PlayerVisibilityTile(
                            name: player.displayName,
                            agent: player.agent,
                            sampleCount: player.samples.length,
                            timeRange:
                                '${_formatMs(player.firstTimeMs)}-${_formatMs(player.lastTimeMs)}',
                            detail: player.confidence ?? player.kind,
                            color: player.teamColor,
                            visible: visible,
                            onChanged: (_) =>
                                notifier.togglePlayerVisibility(player.id),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReplayAbilityEventControls extends ConsumerWidget {
  const _ReplayAbilityEventControls({required this.state});

  final ReplayState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(replayProvider.notifier);
    final events = state.track?.abilityCasts ?? const <ReplayAbilityCast>[];
    final currentIndex = _abilityCastIndexAt(events, state.currentTimeMs);
    final event = currentIndex == -1 ? null : events[currentIndex];
    final enabled = events.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.secondary.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_motion,
                color: Color(0xffa1a1aa),
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  enabled
                      ? 'Cast signal ${currentIndex + 1} of ${events.length}'
                      : 'No decoded cast signals',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ShadIconButton.secondary(
                enabled: enabled,
                onPressed: notifier.seekToPreviousAbilityEvent,
                icon: const Icon(Icons.skip_previous),
              ),
              const SizedBox(width: 6),
              ShadIconButton.secondary(
                enabled: enabled,
                onPressed: notifier.seekToNextAbilityEvent,
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            event == null
                ? 'No canonical cast-statistics signals decoded. On-map utility actors can still be available.'
                : '${_formatMs(event.timeMs)} / ${event.label}',
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            style: const TextStyle(
              color: Color(0xffa1a1aa),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Diagnostic navigator only. Audit targets come from clicking the map.',
            style: TextStyle(
              color: Color(0xff71717a),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ability audit',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Click abilities to review them',
                      style: TextStyle(
                        color: Color(0xff71717a),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: state.abilityAuditEnabled,
                onChanged:
                    state.hasTrack ? notifier.setAbilityAuditEnabled : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReplayAbilityAuditPanel extends ConsumerStatefulWidget {
  const _ReplayAbilityAuditPanel({required this.state});

  final ReplayState state;

  @override
  ConsumerState<_ReplayAbilityAuditPanel> createState() =>
      _ReplayAbilityAuditPanelState();
}

class _ReplayAbilityAuditPanelState
    extends ConsumerState<_ReplayAbilityAuditPanel> {
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void _saveNote(ReplayProvider notifier) {
    final note = _noteController.text.trim();
    if (note.isEmpty) return;
    notifier.addCustomAbilityAuditNote(note);
    _noteController.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final notifier = ref.read(replayProvider.notifier);
    final selectedTarget = state.selectedAbilityAuditTarget;
    final entries = state.abilityAuditEntries;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.secondary.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 430),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      selectedTarget == null
                          ? 'Click an ability icon on the map'
                          : selectedTarget.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selectedTarget == null
                            ? const Color(0xffa1a1aa)
                            : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${entries.length} notes',
                    style: const TextStyle(
                      color: Color(0xff71717a),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (selectedTarget != null) ...[
                const SizedBox(height: 5),
                _AuditTargetEvidenceSummary(target: selectedTarget),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ShadButton.secondary(
                      enabled: entries.isNotEmpty,
                      leading: const Icon(Icons.content_copy, size: 15),
                      onPressed: notifier.copyAbilityAuditJson,
                      child: const Text('Copy JSON'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: ShadButton(
                      enabled: entries.isNotEmpty,
                      leading: const Icon(Icons.download_outlined, size: 15),
                      onPressed: notifier.exportAbilityAudit,
                      child: const Text('Export JSON'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _AuditActionButton(
                    label: 'Missing here',
                    icon: Icons.add_location_alt_outlined,
                    onPressed: () => notifier.beginMapAudit(
                      ReplayAbilityAuditIssue.missing,
                    ),
                  ),
                  _AuditActionButton(
                    label: 'Looks correct',
                    icon: Icons.check,
                    onPressed: selectedTarget == null
                        ? null
                        : () => notifier.addAbilityAuditEntry(
                              ReplayAbilityAuditIssue.correct,
                            ),
                  ),
                  _AuditActionButton(
                    label: 'Wrong ability',
                    icon: Icons.swap_horiz,
                    onPressed: selectedTarget == null
                        ? null
                        : () => notifier.addAbilityAuditEntry(
                              ReplayAbilityAuditIssue.wrongAbility,
                            ),
                  ),
                  _AuditActionButton(
                    label: 'Wrong position',
                    icon: Icons.my_location,
                    onPressed: selectedTarget == null
                        ? null
                        : () => notifier.beginMapAudit(
                              ReplayAbilityAuditIssue.wrongPosition,
                            ),
                  ),
                  _AuditActionButton(
                    label: 'Should not exist',
                    icon: Icons.visibility_off_outlined,
                    onPressed: selectedTarget == null
                        ? null
                        : () => notifier.addAbilityAuditEntry(
                              ReplayAbilityAuditIssue.falsePositive,
                            ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'TIMING AT PLAYHEAD',
                style: TextStyle(
                  color: Color(0xff71717a),
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.7,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final issue in const [
                    ReplayAbilityAuditIssue.startsEarlier,
                    ReplayAbilityAuditIssue.startsLater,
                    ReplayAbilityAuditIssue.endsEarlier,
                    ReplayAbilityAuditIssue.endsLater,
                  ])
                    _AuditActionButton(
                      label: issue.label,
                      onPressed: selectedTarget == null
                          ? null
                          : () => notifier.addAbilityAuditEntry(issue),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'CUSTOM NOTE',
                style: TextStyle(
                  color: Color(0xff71717a),
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.7,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _noteController,
                minLines: 2,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(
                  color: Color(0xfffafafa),
                  fontSize: 12,
                  height: 1.35,
                ),
                decoration: InputDecoration(
                  hintText:
                      'Describe what happened, what should appear, or anything the parser missed...',
                  hintStyle: const TextStyle(
                    color: Color(0xff71717a),
                    fontSize: 11,
                    height: 1.35,
                  ),
                  filled: true,
                  fillColor: Settings.tacticalVioletTheme.card,
                  contentPadding: const EdgeInsets.all(10),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide:
                        BorderSide(color: Settings.tacticalVioletTheme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(
                      color: Settings.tacticalVioletTheme.primary,
                      width: 2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: ShadButton.secondary(
                  enabled: _noteController.text.trim().isNotEmpty,
                  leading: const Icon(Icons.add_comment_outlined, size: 15),
                  onPressed: () => _saveNote(notifier),
                  child: const Text('Add note'),
                ),
              ),
              if (entries.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final entry in entries.reversed.take(2))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(
                          entry.icarusPosition == null
                              ? Icons.bookmark_outline
                              : Icons.location_on_outlined,
                          size: 13,
                          color: const Color(0xffa1a1aa),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${_formatMs(entry.timeMs)}  ${entry.issue.label}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xffa1a1aa),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ShadButton.secondary(
                    leading: const Icon(Icons.undo, size: 15),
                    onPressed: notifier.undoLastAbilityAuditEntry,
                    child: const Text('Undo last'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AuditTargetEvidenceSummary extends StatelessWidget {
  const _AuditTargetEvidenceSummary({required this.target});

  final ReplayAbilityAuditTarget target;

  @override
  Widget build(BuildContext context) {
    final evidence = target.evidence;
    final lifecycleEvidence = evidence['lifecycleEvidence'] as String?;
    final endReason = evidence['endReason'] as String?;
    final endReasonEvidence = evidence['endReasonEvidence'] as String?;
    final fallbackSource = evidence['fallbackDurationSource'] as String?;
    final identitySource = evidence['identitySource'] as String?;

    final description = switch (target.type) {
      ReplayAbilityAuditTargetType.abilityCast => 'Observed cast signal',
      ReplayAbilityAuditTargetType.utilityActor => switch (lifecycleEvidence) {
          'observed' => 'Observed actor lifecycle',
          'derived' => 'Actor timing derived from replay evidence',
          'fallback' => 'Inferred fallback timing',
          'absent' => 'Actor observed, ending not established',
          _ => 'Observed actor target',
        },
    };
    final detailParts = <String>[
      if (identitySource != null)
        'identity ${identitySource.replaceAll('-', ' ')}',
      if (endReason != null) endReason.replaceAll('-', ' '),
      if (endReasonEvidence?.startsWith('derived:') ?? false)
        'derived end reason',
      if (endReason == null && fallbackSource != null)
        fallbackSource.replaceAll('-', ' '),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          lifecycleEvidence == 'fallback'
              ? Icons.warning_amber_rounded
              : Icons.verified_outlined,
          size: 13,
          color: const Color(0xffa1a1aa),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            detailParts.isEmpty
                ? description
                : '$description · ${detailParts.join(' · ')}',
            style: const TextStyle(
              color: Color(0xffa1a1aa),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }
}

class _AuditActionButton extends StatelessWidget {
  const _AuditActionButton({
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 14),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        foregroundColor: const Color(0xfffafafa),
        disabledForegroundColor: const Color(0xff52525b),
        side: BorderSide(color: Settings.tacticalVioletTheme.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ReplayReviewWindowControls extends ConsumerWidget {
  const _ReplayReviewWindowControls({required this.state});

  final ReplayState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(replayProvider.notifier);
    final start = state.reviewWindowStartMs;
    final end = state.reviewWindowEndMs;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.secondary.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ShadIconButton.secondary(
                enabled: state.hasTrack,
                onPressed: () => notifier.shiftReviewWindow(
                  -ReplayState.reviewWindowDurationMs,
                ),
                icon: const Icon(Icons.chevron_left),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${_formatMs(start)} to ${_formatMs(end)}',
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ShadIconButton.secondary(
                enabled: state.hasTrack,
                onPressed: () => notifier.shiftReviewWindow(
                  ReplayState.reviewWindowDurationMs,
                ),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Map trails',
                  style: TextStyle(
                    color: Color(0xffa1a1aa),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                value: state.showReviewTrails,
                onChanged: notifier.setShowReviewTrails,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReplayTimelineGraph extends StatelessWidget {
  const _ReplayTimelineGraph({required this.state});

  final ReplayState state;

  @override
  Widget build(BuildContext context) {
    final track = state.track;
    if (track == null) return const SizedBox.shrink();

    return CustomPaint(
      painter: _ReplayTimelinePainter(
        track: track,
        visiblePlayerIds: state.visiblePlayerIds,
        startMs: state.reviewWindowStartMs,
        endMs: state.reviewWindowEndMs,
        currentTimeMs: state.currentTimeMs,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _ReplayTimelinePainter extends CustomPainter {
  const _ReplayTimelinePainter({
    required this.track,
    required this.visiblePlayerIds,
    required this.startMs,
    required this.endMs,
    required this.currentTimeMs,
  });

  final ReplayTrack track;
  final Set<String> visiblePlayerIds;
  final int startMs;
  final int endMs;
  final int currentTimeMs;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final backgroundPaint = Paint()
      ..color = Settings.tacticalVioletTheme.secondary.withValues(alpha: 0.52);
    final borderPaint = Paint()
      ..color = Settings.tacticalVioletTheme.border
      ..style = PaintingStyle.stroke;
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1;
    final lanePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1;

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), const Radius.circular(8)),
      backgroundPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), const Radius.circular(8)),
      borderPaint,
    );

    for (var tick = 0; tick <= 6; tick += 1) {
      final x = size.width * tick / 6;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    final visible = [
      for (final player in track.players)
        if (visiblePlayerIds.contains(player.id)) player,
    ].take(64).toList();
    if (visible.isEmpty) return;

    final laneHeight = size.height / math.max(visible.length, 1);
    final span = math.max(1, endMs - startMs);
    for (var index = 0; index < visible.length; index += 1) {
      final player = visible[index];
      final y = laneHeight * index + laneHeight / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), lanePaint);
      final samples = player.samplesBetween(startMs, endMs);
      for (final sample in samples) {
        final x =
            ((sample.timeMs - startMs) / span).clamp(0.0, 1.0) * size.width;
        canvas.drawCircle(
          Offset(x, y),
          math.max(1.6, math.min(3.2, laneHeight * 0.32)),
          Paint()..color = player.teamColor.withValues(alpha: 0.9),
        );
      }
    }

    if (currentTimeMs >= startMs && currentTimeMs <= endMs) {
      final x = ((currentTimeMs - startMs) / span) * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Settings.tacticalVioletTheme.primary
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ReplayTimelinePainter oldDelegate) {
    return oldDelegate.track != track ||
        oldDelegate.visiblePlayerIds != visiblePlayerIds ||
        oldDelegate.startMs != startMs ||
        oldDelegate.endMs != endMs ||
        oldDelegate.currentTimeMs != currentTimeMs;
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xffa1a1aa),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerVisibilityTile extends StatelessWidget {
  const _PlayerVisibilityTile({
    required this.name,
    required this.agent,
    required this.sampleCount,
    required this.timeRange,
    required this.detail,
    required this.color,
    required this.visible,
    required this.onChanged,
  });

  final String name;
  final String? agent;
  final int sampleCount;
  final String timeRange;
  final String? detail;
  final Color color;
  final bool visible;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.secondary.withValues(alpha: 0.64),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (agent != null && agent!.isNotEmpty)
                  Text(
                    [
                      agent!,
                      '$sampleCount samples',
                      timeRange,
                    ].join(' / '),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xffa1a1aa),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (detail != null && detail!.isNotEmpty)
                  Text(
                    detail!,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xff71717a),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          Switch(value: visible, onChanged: onChanged),
        ],
      ),
    );
  }
}

String _formatMs(int ms) {
  final totalSeconds = (ms / 1000).floor();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

bool _hasCandidateEntities(ReplayTrack? track) {
  return track?.players
          .any((player) => player.kind?.startsWith('candidate') ?? false) ??
      false;
}

int _abilityCastIndexAt(List<ReplayAbilityCast> events, int currentTimeMs) {
  if (events.isEmpty) return -1;
  var index = 0;
  for (var i = 0; i < events.length; i += 1) {
    if (events[i].timeMs <= currentTimeMs) {
      index = i;
    } else {
      break;
    }
  }
  return index;
}
