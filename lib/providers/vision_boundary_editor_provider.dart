import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/services/vision_boundary_asset_writer.dart';
import 'package:icarus/view_cone/vision_boundary_edit_document.dart';

final visionBoundaryEditorProvider =
    NotifierProvider<VisionBoundaryEditorProvider, VisionBoundaryEditorState>(
  VisionBoundaryEditorProvider.new,
);

class VisionBoundaryEditorState {
  const VisionBoundaryEditorState({
    this.isOpen = false,
    this.isLoading = false,
    this.isSaving = false,
    this.map,
    this.attackTargetBounds,
    this.draft,
    this.committedDraft,
    this.selection,
    this.scope = VisionBoundaryEditScope.point,
    this.isDirty = false,
    this.error,
  });

  final bool isOpen;
  final bool isLoading;
  final bool isSaving;
  final MapValue? map;
  final Rect? attackTargetBounds;
  final VisionBoundaryMapDraft? draft;
  final VisionBoundaryMapDraft? committedDraft;
  final VisionBoundarySelection? selection;
  final VisionBoundaryEditScope scope;
  final bool isDirty;
  final String? error;

  VisionBoundaryEditorState copyWith({
    bool? isOpen,
    bool? isLoading,
    bool? isSaving,
    MapValue? map,
    Rect? attackTargetBounds,
    VisionBoundaryMapDraft? draft,
    VisionBoundaryMapDraft? committedDraft,
    VisionBoundarySelection? selection,
    bool clearSelection = false,
    VisionBoundaryEditScope? scope,
    bool? isDirty,
    String? error,
    bool clearError = false,
  }) {
    return VisionBoundaryEditorState(
      isOpen: isOpen ?? this.isOpen,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      map: map ?? this.map,
      attackTargetBounds: attackTargetBounds ?? this.attackTargetBounds,
      draft: draft ?? this.draft,
      committedDraft: committedDraft ?? this.committedDraft,
      selection: clearSelection ? null : selection ?? this.selection,
      scope: scope ?? this.scope,
      isDirty: isDirty ?? this.isDirty,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class VisionBoundarySaveResult {
  const VisionBoundarySaveResult({required this.contents, required this.path});

  final String contents;
  final String? path;
}

class VisionBoundaryEditorProvider extends Notifier<VisionBoundaryEditorState> {
  final List<VisionBoundaryMapDraft> _undo = [];
  final List<VisionBoundaryMapDraft> _redo = [];
  Map<String, dynamic>? _editDocument;
  VisionBoundaryMapDraft? _persistedDraft;
  VisionBoundaryMapDraft? _dragStartDraft;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  @override
  VisionBoundaryEditorState build() => const VisionBoundaryEditorState();

  Future<void> open({
    required MapValue map,
    required Rect attackTargetBounds,
  }) async {
    if (state.isOpen && state.map == map && state.draft != null) return;
    if (state.isDirty) {
      throw StateError('Save or discard the current boundary edits first.');
    }
    state = VisionBoundaryEditorState(
      isOpen: true,
      isLoading: true,
      map: map,
      attackTargetBounds: attackTargetBounds,
    );
    try {
      final sources = await Future.wait([
        rootBundle.loadString(visionBoundaryReferenceAsset),
        rootBundle.loadString(visionBoundaryEditsAsset),
      ]);
      final reference = _decodeDocument(sources[0]);
      final edits = _decodeDocument(sources[1]);
      final merged = mergeVisionBoundaryDocuments(
        reference: reference,
        edits: edits,
      );
      final maps = merged['maps']! as Map<String, dynamic>;
      final draft = VisionBoundaryMapDraft.fromJson(
        map: map,
        value: maps[map.name],
      );
      _editDocument = edits;
      _persistedDraft = draft;
      _undo.clear();
      _redo.clear();
      _dragStartDraft = null;
      state = VisionBoundaryEditorState(
        isOpen: true,
        map: map,
        attackTargetBounds: attackTargetBounds,
        draft: draft,
        committedDraft: draft,
      );
    } on Object catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Could not load the boundary editor: $error',
      );
    }
  }

  bool close() {
    if (state.isDirty) return false;
    _undo.clear();
    _redo.clear();
    _dragStartDraft = null;
    state = const VisionBoundaryEditorState();
    return true;
  }

  void setScope(VisionBoundaryEditScope scope) {
    var selection = state.selection;
    if (scope == VisionBoundaryEditScope.contour) {
      selection = selection?.withoutPoint();
    }
    state = state.copyWith(
      scope: scope,
      selection: selection,
      clearSelection: selection == null,
    );
  }

  void select(VisionBoundarySelection? selection) {
    state = state.copyWith(
      selection: selection,
      clearSelection: selection == null,
    );
  }

  void beginEdit() {
    final draft = state.draft;
    if (draft == null || _dragStartDraft != null) return;
    _dragStartDraft = draft;
    _undo.add(draft);
    _redo.clear();
  }

  void moveSelectionBy(Offset sourceDelta) {
    final draft = state.draft;
    if (draft == null || sourceDelta == Offset.zero) return;
    final moved = draft.move(
      selection: state.selection,
      scope: state.scope,
      sourceDelta: sourceDelta,
    );
    if (identical(moved, draft)) return;
    state = state.copyWith(draft: moved);
  }

  void commitEdit() {
    final dragStart = _dragStartDraft;
    final draft = state.draft;
    _dragStartDraft = null;
    if (dragStart == null || draft == null) return;
    if (dragStart.signature == draft.signature) {
      if (_undo.isNotEmpty && identical(_undo.last, dragStart)) {
        _undo.removeLast();
      }
      return;
    }
    state = state.copyWith(committedDraft: draft, isDirty: _isDirty(draft));
  }

  void cancelEdit() {
    final dragStart = _dragStartDraft;
    _dragStartDraft = null;
    if (dragStart == null) return;
    if (_undo.isNotEmpty && identical(_undo.last, dragStart)) {
      _undo.removeLast();
    }
    state = state.copyWith(draft: dragStart);
  }

  void nudge(Offset sourceDelta) {
    if (!_hasMovableSelection || sourceDelta == Offset.zero) return;
    beginEdit();
    moveSelectionBy(sourceDelta);
    commitEdit();
  }

  void undo() {
    final draft = state.draft;
    if (draft == null || _undo.isEmpty) return;
    final previous = _undo.removeLast();
    _redo.add(draft);
    state = state.copyWith(
      draft: previous,
      committedDraft: previous,
      isDirty: _isDirty(previous),
    );
  }

  void redo() {
    final draft = state.draft;
    if (draft == null || _redo.isEmpty) return;
    final next = _redo.removeLast();
    _undo.add(draft);
    state = state.copyWith(
      draft: next,
      committedDraft: next,
      isDirty: _isDirty(next),
    );
  }

  void discardChanges() {
    final persisted = _persistedDraft;
    if (persisted == null) return;
    _undo.clear();
    _redo.clear();
    _dragStartDraft = null;
    state = state.copyWith(
      draft: persisted,
      committedDraft: persisted,
      isDirty: false,
      clearSelection: true,
      clearError: true,
    );
  }

  Future<VisionBoundarySaveResult> save() async {
    final draft = state.draft;
    final edits = _editDocument;
    if (draft == null || edits == null) {
      throw StateError('The boundary editor is not ready.');
    }
    state = state.copyWith(isSaving: true, clearError: true);
    final contents = _serializeEdits(edits, draft);
    try {
      final path = await writeVisionBoundaryEditsAsset(contents);
      if (path != null) {
        final updated = _decodeDocument(contents);
        _editDocument = updated;
        _persistedDraft = draft;
        state = state.copyWith(isSaving: false, isDirty: false);
      } else {
        state = state.copyWith(isSaving: false);
      }
      return VisionBoundarySaveResult(contents: contents, path: path);
    } on Object catch (error) {
      state = state.copyWith(
        isSaving: false,
        error: 'Could not save boundary edits: $error',
      );
      rethrow;
    }
  }

  String copyPayload() {
    final draft = state.draft;
    final edits = _editDocument;
    if (draft == null || edits == null) {
      throw StateError('The boundary editor is not ready.');
    }
    return _serializeEdits(edits, draft);
  }

  bool get _hasMovableSelection =>
      state.scope == VisionBoundaryEditScope.all ||
      (state.selection != null &&
          (state.scope != VisionBoundaryEditScope.point ||
              state.selection!.pointIndex != null));

  bool _isDirty(VisionBoundaryMapDraft draft) =>
      draft.signature != _persistedDraft?.signature;

  static Map<String, dynamic> _decodeDocument(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Vision boundary asset must be an object.');
    }
    return decoded;
  }

  static String _serializeEdits(
    Map<String, dynamic> edits,
    VisionBoundaryMapDraft draft,
  ) {
    final maps = edits['maps'];
    if (edits['version'] != 1 || maps is! Map<String, dynamic>) {
      throw const FormatException('Invalid collision edit manifest.');
    }
    final sortedMaps = <String, dynamic>{
      ...maps,
      draft.map.name: draft.toJson(),
    };
    final orderedNames = sortedMaps.keys.toList()..sort();
    final document = <String, dynamic>{
      'version': 1,
      'maps': <String, dynamic>{
        for (final name in orderedNames) name: sortedMaps[name],
      },
    };
    return '${const JsonEncoder.withIndent('  ').convert(document)}\n';
  }
}
