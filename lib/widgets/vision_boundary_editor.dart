import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/view_cone_debug_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/providers/vision_boundary_editor_provider.dart';
import 'package:icarus/view_cone/vision_boundary_edit_document.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class VisionBoundaryEditorOverlay extends ConsumerStatefulWidget {
  const VisionBoundaryEditorOverlay({super.key});

  @override
  ConsumerState<VisionBoundaryEditorOverlay> createState() =>
      _VisionBoundaryEditorOverlayState();
}

class _VisionBoundaryEditorOverlayState
    extends ConsumerState<VisionBoundaryEditorOverlay> {
  Offset? _lastSourcePosition;
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(visionBoundaryEditorProvider);
    final mapState = ref.watch(mapProvider);
    final draft = editor.draft;
    final targetBounds = editor.attackTargetBounds;
    if (!editor.isOpen ||
        editor.isLoading ||
        draft == null ||
        targetBounds == null ||
        editor.map != mapState.currentMap) {
      return const SizedBox.shrink();
    }

    final coordinateSystem = CoordinateSystem.instance;
    final zoom = ref.watch(screenZoomProvider).clamp(1.0, 8.0);
    final isDefense = !mapState.isAttack;

    Offset toScreen(Offset source) => coordinateSystem.coordinateToScreen(
          draft.project(
            source,
            attackTargetBounds: targetBounds,
            isDefense: isDefense,
          ),
        );

    Offset toSource(Offset local) => draft.unproject(
          coordinateSystem.screenToCoordinate(local),
          attackTargetBounds: targetBounds,
          isDefense: isDefense,
        );

    VisionBoundarySelection? hitTest(Offset local) {
      final pointTolerance = 12 / zoom;
      final lineTolerance = 10 / zoom;
      VisionBoundarySelection? closestPoint;
      var closestPointDistance = double.infinity;
      VisionBoundarySelection? closestContour;
      var closestLineDistance = double.infinity;

      for (final contourRef in draft.contourRefs) {
        final points = draft.contour(contourRef);
        for (var index = 0; index < points.length; index += 1) {
          final pointDistance = (toScreen(points[index]) - local).distance;
          if (pointDistance <= pointTolerance &&
              pointDistance < closestPointDistance) {
            closestPointDistance = pointDistance;
            closestPoint = VisionBoundarySelection(
              contour: contourRef,
              pointIndex: index,
            );
          }
        }
        final segmentCount = draft.isClosed(contourRef)
            ? points.length
            : math.max(0, points.length - 1);
        for (var index = 0; index < segmentCount; index += 1) {
          final next = (index + 1) % points.length;
          final lineDistance = _distanceToSegment(
            local,
            toScreen(points[index]),
            toScreen(points[next]),
          );
          if (lineDistance <= lineTolerance &&
              lineDistance < closestLineDistance) {
            closestLineDistance = lineDistance;
            closestContour = VisionBoundarySelection(contour: contourRef);
          }
        }
      }

      if (editor.scope == VisionBoundaryEditScope.point) return closestPoint;
      return closestContour ?? closestPoint?.withoutPoint();
    }

    return MouseRegion(
      cursor: editor.scope == VisionBoundaryEditScope.point
          ? SystemMouseCursors.precise
          : SystemMouseCursors.move,
      child: GestureDetector(
        key: const ValueKey('vision-boundary-editor-canvas'),
        behavior: HitTestBehavior.translucent,
        onTapDown: (details) {
          ref
              .read(visionBoundaryEditorProvider.notifier)
              .select(hitTest(details.localPosition));
        },
        onPanStart: (details) {
          final selection = hitTest(details.localPosition);
          if (selection == null &&
              editor.scope != VisionBoundaryEditScope.all) {
            return;
          }
          final notifier = ref.read(visionBoundaryEditorProvider.notifier);
          notifier.select(selection);
          notifier.beginEdit();
          _lastSourcePosition = toSource(details.localPosition);
          _isDragging = true;
        },
        onPanUpdate: (details) {
          if (!_isDragging || _lastSourcePosition == null) return;
          final next = toSource(details.localPosition);
          ref
              .read(visionBoundaryEditorProvider.notifier)
              .moveSelectionBy(next - _lastSourcePosition!);
          _lastSourcePosition = next;
        },
        onPanEnd: (_) {
          if (!_isDragging) return;
          _isDragging = false;
          _lastSourcePosition = null;
          ref.read(visionBoundaryEditorProvider.notifier).commitEdit();
        },
        onPanCancel: () {
          if (!_isDragging) return;
          _isDragging = false;
          _lastSourcePosition = null;
          ref.read(visionBoundaryEditorProvider.notifier).cancelEdit();
        },
        child: RepaintBoundary(
          child: CustomPaint(
            painter: VisionBoundaryEditorPainter(
              draft: draft,
              attackTargetBounds: targetBounds,
              isDefense: isDefense,
              selection: editor.selection,
              scope: editor.scope,
              coordinateSystem: coordinateSystem,
              zoom: zoom,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class VisionBoundaryEditorHud extends ConsumerWidget {
  const VisionBoundaryEditorHud({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kDebugMode) return const SizedBox.shrink();
    final editor = ref.watch(visionBoundaryEditorProvider);
    final mapState = ref.watch(mapProvider);
    final geometry = ref.watch(viewConeGeometryProvider(mapState.currentMap));

    if (!editor.isOpen) {
      final boundary = geometry.asData?.value?.attackLayers.first.boundary;
      return ShadTooltip(
        builder: (_) => const Text('Edit vision boundary'),
        child: ShadIconButton.secondary(
          key: const ValueKey('open-vision-boundary-editor'),
          width: 40,
          height: 40,
          enabled: boundary != null,
          onPressed: boundary == null
              ? null
              : () async {
                  try {
                    await ref.read(visionBoundaryEditorProvider.notifier).open(
                          map: mapState.currentMap,
                          attackTargetBounds: boundary.outerGroup.bounds,
                          boundary: boundary,
                        );
                    ref.read(viewConeDebugProvider.notifier).state = true;
                  } on Object catch (error) {
                    Settings.showToast(
                      message: error.toString(),
                      backgroundColor: Settings.tacticalVioletTheme.destructive,
                    );
                  }
                },
          icon: const Icon(Icons.polyline_outlined, size: 20),
        ),
      );
    }

    return _VisionBoundaryEditorPanel(
      isCurrentMap: editor.map == mapState.currentMap,
    );
  }
}

class _VisionBoundaryEditorPanel extends ConsumerWidget {
  const _VisionBoundaryEditorPanel({required this.isCurrentMap});

  final bool isCurrentMap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final editor = ref.watch(visionBoundaryEditorProvider);
    final notifier = ref.read(visionBoundaryEditorProvider.notifier);
    final mapLabel = editor.map == null
        ? 'Map'
        : Maps.mapNames[editor.map]![0].toUpperCase() +
            Maps.mapNames[editor.map]!.substring(1);

    return Material(
      color: Colors.transparent,
      child: Container(
        key: const ValueKey('vision-boundary-editor-panel'),
        width: 600,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.border),
          boxShadow: const [Settings.cardForegroundBackdrop],
        ),
        child: editor.isLoading
            ? const SizedBox(
                height: 56,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.polyline_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Vision boundary · $mapLabel',
                              style: theme.textTheme.small.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Attack, defense, and every elevation update together.',
                              style: theme.textTheme.small.copyWith(
                                color: theme.colorScheme.mutedForeground,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (editor.isDirty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondary,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'Unsaved',
                            style: theme.textTheme.small.copyWith(fontSize: 11),
                          ),
                        ),
                      const SizedBox(width: 6),
                      ShadIconButton.ghost(
                        width: 32,
                        height: 32,
                        onPressed: () {
                          if (!notifier.close()) {
                            Settings.showToast(
                              message:
                                  'Save or discard the boundary edits first.',
                              backgroundColor:
                                  Settings.tacticalVioletTheme.destructive,
                            );
                          }
                        },
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (editor.error != null) ...[
                    Text(
                      editor.error!,
                      style: theme.textTheme.small.copyWith(
                        color: theme.colorScheme.destructive,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (!isCurrentMap) ...[
                    Text(
                      'The editor is paused because another map is selected.',
                      style: theme.textTheme.small,
                    ),
                    const SizedBox(height: 10),
                    ShadButton.secondary(
                      onPressed: () {
                        final map = editor.map;
                        if (map != null) {
                          ref.read(mapProvider.notifier).updateMap(map);
                        }
                      },
                      child: Text('Return to $mapLabel'),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Text(
                          'Move',
                          style: theme.textTheme.small.copyWith(
                            color: theme.colorScheme.mutedForeground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _ScopeButton(
                          label: 'Point',
                          selected:
                              editor.scope == VisionBoundaryEditScope.point,
                          onPressed: () =>
                              notifier.setScope(VisionBoundaryEditScope.point),
                        ),
                        const SizedBox(width: 6),
                        _ScopeButton(
                          label: 'Contour',
                          selected:
                              editor.scope == VisionBoundaryEditScope.contour,
                          onPressed: () => notifier.setScope(
                            VisionBoundaryEditScope.contour,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _ScopeButton(
                          label: 'Everything',
                          selected: editor.scope == VisionBoundaryEditScope.all,
                          onPressed: () =>
                              notifier.setScope(VisionBoundaryEditScope.all),
                        ),
                        const Spacer(),
                        ShadIconButton.ghost(
                          width: 32,
                          height: 32,
                          enabled: notifier.canUndo,
                          onPressed: notifier.canUndo ? notifier.undo : null,
                          icon: const Icon(Icons.undo, size: 18),
                        ),
                        ShadIconButton.ghost(
                          width: 32,
                          height: 32,
                          enabled: notifier.canRedo,
                          onPressed: notifier.canRedo ? notifier.redo : null,
                          icon: const Icon(Icons.redo, size: 18),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            editor.scope == VisionBoundaryEditScope.all
                                ? 'Everything selected'
                                : editor.selection?.label ??
                                    'Select a ${editor.scope == VisionBoundaryEditScope.point ? 'point' : 'wireframe'}',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.small,
                          ),
                        ),
                        Text(
                          'Nudge',
                          style: theme.textTheme.small.copyWith(
                            color: theme.colorScheme.mutedForeground,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 4),
                        _NudgeButton(
                          icon: Icons.keyboard_arrow_left,
                          onPressed: () => notifier.nudge(const Offset(-1, 0)),
                        ),
                        _NudgeButton(
                          icon: Icons.keyboard_arrow_up,
                          onPressed: () => notifier.nudge(const Offset(0, -1)),
                        ),
                        _NudgeButton(
                          icon: Icons.keyboard_arrow_down,
                          onPressed: () => notifier.nudge(const Offset(0, 1)),
                        ),
                        _NudgeButton(
                          icon: Icons.keyboard_arrow_right,
                          onPressed: () => notifier.nudge(const Offset(1, 0)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ShadButton.outline(
                          enabled: editor.isDirty,
                          onPressed:
                              editor.isDirty ? notifier.discardChanges : null,
                          leading: const Icon(Icons.restart_alt, size: 16),
                          child: const Text('Discard'),
                        ),
                        const SizedBox(width: 8),
                        ShadButton.secondary(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: notifier.copyPayload()),
                            );
                            Settings.showToast(
                              message: 'Boundary edit JSON copied.',
                              backgroundColor:
                                  Settings.tacticalVioletTheme.primary,
                            );
                          },
                          leading: const Icon(Icons.copy, size: 16),
                          child: const Text('Copy JSON'),
                        ),
                        const Spacer(),
                        ShadButton(
                          key: const ValueKey('save-vision-boundary-edits'),
                          enabled: editor.isDirty && !editor.isSaving,
                          onPressed: !editor.isDirty || editor.isSaving
                              ? null
                              : () async {
                                  try {
                                    final result = await notifier.save();
                                    if (result.path == null) {
                                      await Clipboard.setData(
                                        ClipboardData(text: result.contents),
                                      );
                                      Settings.showToast(
                                        message:
                                            'Source tree not found; boundary JSON copied instead.',
                                        backgroundColor: Settings
                                            .tacticalVioletTheme.primary,
                                      );
                                    } else {
                                      Settings.showToast(
                                        message:
                                            'Saved vision_boundary_edits.json.',
                                        backgroundColor: Settings
                                            .tacticalVioletTheme.primary,
                                      );
                                    }
                                  } on Object catch (_) {
                                    Settings.showToast(
                                      message: 'Could not save boundary edits.',
                                      backgroundColor: Settings
                                          .tacticalVioletTheme.destructive,
                                    );
                                  }
                                },
                          leading: editor.isSaving
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_outlined, size: 16),
                          child: const Text('Save asset'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _ScopeButton extends StatelessWidget {
  const _ScopeButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final child = Text(label);
    return selected
        ? ShadButton(height: 32, onPressed: onPressed, child: child)
        : ShadButton.secondary(height: 32, onPressed: onPressed, child: child);
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ShadIconButton.ghost(
      width: 28,
      height: 28,
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
    );
  }
}

class VisionBoundaryEditorPainter extends CustomPainter {
  VisionBoundaryEditorPainter({
    required this.draft,
    required this.attackTargetBounds,
    required this.isDefense,
    required this.selection,
    required this.scope,
    required this.coordinateSystem,
    required this.zoom,
  });

  final VisionBoundaryMapDraft draft;
  final Rect attackTargetBounds;
  final bool isDefense;
  final VisionBoundarySelection? selection;
  final VisionBoundaryEditScope scope;
  final CoordinateSystem coordinateSystem;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final normalPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25 / zoom;
    final selectedPaint = Paint()
      ..color = Settings.tacticalVioletTheme.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 / zoom;
    final pointPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.72)
      ..style = PaintingStyle.fill;
    final selectedPointPaint = Paint()
      ..color = Settings.tacticalVioletTheme.primary
      ..style = PaintingStyle.fill;

    Offset toScreen(Offset source) => coordinateSystem.coordinateToScreen(
          draft.project(
            source,
            attackTargetBounds: attackTargetBounds,
            isDefense: isDefense,
          ),
        );

    for (final contourRef in draft.contourRefs) {
      final points = draft.contour(contourRef);
      if (points.isEmpty) continue;
      final path = Path()
        ..moveTo(toScreen(points.first).dx, toScreen(points.first).dy);
      for (final point in points.skip(1)) {
        final screen = toScreen(point);
        path.lineTo(screen.dx, screen.dy);
      }
      if (draft.isClosed(contourRef)) path.close();
      final isSelected = scope == VisionBoundaryEditScope.all ||
          selection?.contour == contourRef;
      canvas.drawPath(path, isSelected ? selectedPaint : normalPaint);

      final showPoints = scope == VisionBoundaryEditScope.point &&
          (selection == null || selection?.contour == contourRef);
      if (!showPoints) continue;
      for (var index = 0; index < points.length; index += 1) {
        final isSelectedPoint =
            selection?.contour == contourRef && selection?.pointIndex == index;
        canvas.drawCircle(
          toScreen(points[index]),
          (isSelectedPoint ? 5 : 2.5) / zoom,
          isSelectedPoint ? selectedPointPaint : pointPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant VisionBoundaryEditorPainter oldDelegate) =>
      oldDelegate.draft != draft ||
      oldDelegate.attackTargetBounds != attackTargetBounds ||
      oldDelegate.isDefense != isDefense ||
      oldDelegate.selection != selection ||
      oldDelegate.scope != scope ||
      oldDelegate.coordinateSystem != coordinateSystem ||
      oldDelegate.zoom != zoom;
}

double _distanceToSegment(Offset point, Offset start, Offset end) {
  final segment = end - start;
  final lengthSquared = segment.distanceSquared;
  if (lengthSquared == 0) return (point - start).distance;
  final fraction =
      ((point - start).dx * segment.dx + (point - start).dy * segment.dy) /
          lengthSquared;
  final clamped = math.max(0.0, math.min(1.0, fraction));
  return (point - (start + segment * clamped)).distance;
}
