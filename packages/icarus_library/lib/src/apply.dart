import 'dart:math' as math;

import 'package:collection/collection.dart';

import 'derived_id.dart';
import 'field_merge.dart';
import 'json.dart';
import 'ops.dart';
import 'outcome.dart';
import 'page_copy.dart';
import 'payloads.dart';
import 'rows.dart';
import 'strategy_rows.dart';

ApplyResult applyOp(StrategyRows rows, StrategyOp op) {
  if (exceedsSizePolicy(op.toJson())) {
    return _failed(FailureCode.invalidPayload);
  }
  final apply = _Apply(rows, undoOpId(op.opId), op.opId);
  return switch (op) {
    StrategyPatchOp() => apply.strategyPatch(op),
    PageAddOp() => apply.pageAdd(op),
    PagePatchOp() => apply.pagePatch(op),
    PageDeleteOp() => apply.pageDelete(op),
    PageReorderOp() => apply.pageReorder(op),
    PageSettingsPatchOp() => apply.pageSettingsPatch(op),
    ElementAddOp() => apply.elementAdd(op),
    ElementPatchOp() => apply.elementPatch(op),
    ElementDeleteOp() => apply.elementDelete(op),
    ElementReorderOp() => apply.elementReorder(op),
    LineupGroupAddOp() => apply.lineupGroupAdd(op),
    LineupGroupPatchOp() => apply.lineupGroupPatch(op),
    LineupGroupDeleteOp() => apply.lineupGroupDelete(op),
    LineupGroupReorderOp() => apply.lineupGroupReorder(op),
  };
}

OpRefused _failed(FailureCode code) => OpRefused(Failed(code));

OpRefused _rejected(RejectionReason reason) => OpRefused(Rejected(reason));

OpRefused? _revisionRefusal(int? expected, int current) {
  if (expected == null) {
    return _rejected(RejectionReason.missingExpectedRevision);
  }
  if (expected != current) return _rejected(RejectionReason.revisionMismatch);
  return null;
}

sealed class _Target<T> {
  const _Target();
}

final class _Found<T> extends _Target<T> {
  const _Found(this.row);

  final T row;
}

final class _Refused<T> extends _Target<T> {
  const _Refused(this.refusal);

  final OpRefused refusal;
}

final class _Apply {
  _Apply(this.rows, this.undoId, this.opId);

  final StrategyRows rows;
  final String undoId;
  final String opId;

  ReadableStrategy get strategy => rows.strategy;

  _Target<List<_Slot>> get placedPages {
    final slots = <_Slot>[];
    for (final page in rows.pages) {
      switch (page) {
        case final LivePage live:
          slots.add(_LiveSlot(live));
        case TrashedPage() || UnreadablePage(trashed: true):
          break;
        case UnreadablePage(sortIndex: final int sortIndex):
          slots.add(_HeldSlot(page, sortIndex));
        case UnreadablePage():
          return _Refused(OpRefused(UnreadableTarget(page.key)));
      }
    }
    mergeSort(
      slots,
      compare: (a, b) => switch (a.sortIndex.compareTo(b.sortIndex)) {
        0 => a.publicId.compareTo(b.publicId),
        final order => order,
      },
    );
    return _Found(slots);
  }

  RowChanged strategyRaised() =>
      _changed(strategy, strategy.rewritten(revision: strategy.revision + 1));

  _Target<List<RowWrite>> placed(List<_Slot> order) {
    final writes = <RowWrite>[];
    for (final (index, slot) in order.indexed) {
      switch (slot) {
        case _LiveSlot(:final page):
          if (_placed(page, index) case final write?) writes.add(write);
        case _HeldSlot(:final page, :final sortIndex) when sortIndex != index:
          return _Refused(OpRefused(UnreadableTarget(page.key)));
        case _HeldSlot() || _NewSlot():
          break;
      }
    }
    return _Found(writes);
  }

  ApplyResult strategyPatch(StrategyPatchOp op) {
    final current = strategy;
    final after = current.rewritten(
      name: op.name,
      mapData: op.mapData,
      themeProfileId: op.themeProfile,
      themeOverridePalette: op.themeOverridePalette,
      revision: current.revision + 1,
    );
    final write = _changed(current, after);
    if (write.fields.isEmpty) return const OpUnchanged();
    if (_revisionRefusal(op.expectedStrategyRevision, current.revision)
        case final refused?) {
      return refused;
    }
    final fields = write.fields;
    return OpApplied(
      writes: [write],
      undo: UndoWithOp(
        StrategyPatchOp(
          opId: undoId,
          expectedStrategyRevision: after.revision,
          name: fields.contains(RowField.name) ? current.name : null,
          mapData: fields.contains(RowField.mapData) ? current.mapData : null,
          themeProfile: fields.contains(RowField.themeProfileId)
              ? _restoring(current.themeProfileId)
              : const KeepValue(),
          themeOverridePalette: fields.contains(RowField.themeOverridePalette)
              ? _restoring(current.themeOverridePalette)
              : const KeepValue(),
        ),
      ),
    );
  }

  ApplyResult pageAdd(PageAddOp op) {
    final List<_Slot> ordered;
    switch (placedPages) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        ordered = row;
    }
    switch (rows.page(op.pagePublicId)) {
      case TrashedPage():
        return _failed(FailureCode.pageDeleted);
      case UnreadablePage(:final RowKey key):
        return OpRefused(UnreadableTarget(key));
      case final LivePage existing:
        final ReadablePageSettings settings;
        switch (rows.settingsOf(existing.publicId)) {
          case null:
            return _failed(FailureCode.invalidPageContentCount);
          case UnreadablePageSettings(:final RowKey key):
            return OpRefused(UnreadableTarget(key));
          case final ReadablePageSettings readable:
            settings = readable;
        }
        final desired = _clamp(op.sortIndex, math.max(0, ordered.length - 1));
        final identical =
            existing.name == (op.name ?? 'Page') &&
            existing.isAutoNamed == op.isAutoNamed &&
            existing.sortIndex == desired &&
            existing.isAttack == (op.isAttack ?? true) &&
            settings.settings == op.settings;
        return identical
            ? const OpUnchanged()
            : _rejected(RejectionReason.alreadyExists);
      case null:
        break;
    }
    if (_revisionRefusal(op.expectedStrategyRevision, strategy.revision)
        case final refused?) {
      return refused;
    }
    final desired = _clamp(op.sortIndex, ordered.length);
    final page = LivePage(
      publicId: op.pagePublicId,
      strategyPublicId: strategy.publicId,
      name: op.name ?? 'Page',
      isAutoNamed: op.isAutoNamed,
      sortIndex: desired,
      isAttack: op.isAttack ?? true,
      revision: 1,
    );
    final source = switch (op.copyContentFromPagePublicId) {
      final id? => rows.page(id),
      null => null,
    };
    if (source is LivePage) {
      if (_uncopyable(source.publicId) case final refused?) return refused;
    }
    final List<RowWrite> moved;
    switch (placed([
      ...ordered.take(desired),
      _NewSlot(),
      ...ordered.skip(desired),
    ])) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        moved = row;
    }
    return OpApplied(
      writes: [
        ...moved,
        RowAdded(page),
        RowAdded(
          ReadablePageSettings(
            pagePublicId: page.publicId,
            settings: op.settings,
            revision: 1,
          ),
        ),
        if (source is LivePage)
          for (final row in PageCopy(opId, rows).content(
            rows.elementsOn(source.publicId),
            rows.lineupGroupsOn(source.publicId),
            page.publicId,
          ))
            RowAdded(row),
        strategyRaised(),
      ],
      undo: UndoWithOp(
        PageDeleteOp(
          opId: undoId,
          pagePublicId: page.publicId,
          expectedStrategyRevision: strategy.revision + 1,
        ),
      ),
    );
  }

  ApplyResult pageDelete(PageDeleteOp op) {
    final LivePage existing;
    switch (rows.page(op.pagePublicId)) {
      case UnreadablePage(:final RowKey key):
        return OpRefused(UnreadableTarget(key));
      case null || TrashedPage():
        return const OpUnchanged();
      case final LivePage page:
        existing = page;
    }
    if (_revisionRefusal(op.expectedStrategyRevision, strategy.revision)
        case final refused?) {
      return refused;
    }
    final List<_Slot> live;
    switch (placedPages) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        live = row;
    }
    if (live.length <= 1) return _failed(FailureCode.invalidOp);
    final List<RowWrite> moved;
    switch (placed([
      for (final slot in live)
        if (slot.publicId != existing.publicId) slot,
    ])) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        moved = row;
    }
    return OpApplied(
      writes: [
        _changed(existing, existing.trashed()),
        ...moved,
        strategyRaised(),
      ],
      undo: UndoByRestoringPage(existing.publicId),
    );
  }

  _Target<LivePage> livePage(String pagePublicId) =>
      switch (rows.page(pagePublicId)) {
        null => _Refused(_rejected(RejectionReason.notFound)),
        TrashedPage() => _Refused(_failed(FailureCode.pageDeleted)),
        UnreadablePage(:final RowKey key) => _Refused(
          OpRefused(UnreadableTarget(key)),
        ),
        final LivePage page => _Found(page),
      };

  ApplyResult pageReorder(PageReorderOp op) {
    final LivePage existing;
    switch (livePage(op.pagePublicId)) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        existing = row;
    }
    final List<_Slot> ordered;
    switch (placedPages) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        ordered = row;
    }
    final currentIndex = ordered.indexWhere(
      (slot) => slot.publicId == existing.publicId,
    );
    final desired = _clamp(op.sortIndex, math.max(0, ordered.length - 1));
    final reordered = [
      for (final slot in ordered)
        if (slot.publicId != existing.publicId) slot,
    ]..insert(desired, _LiveSlot(existing));
    final normalized = reordered.indexed.every(
      (entry) => entry.$2.sortIndex == entry.$1,
    );
    if (currentIndex == desired && normalized) return const OpUnchanged();
    if (_revisionRefusal(op.expectedStrategyRevision, strategy.revision)
        case final refused?) {
      return refused;
    }
    final List<RowWrite> moved;
    switch (placed(reordered)) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        moved = row;
    }
    return OpApplied(
      writes: [...moved, strategyRaised()],
      undo: UndoWithOp(
        PageReorderOp(
          opId: undoId,
          pagePublicId: existing.publicId,
          sortIndex: currentIndex,
          expectedStrategyRevision: strategy.revision + 1,
        ),
      ),
    );
  }

  ApplyResult pagePatch(PagePatchOp op) {
    final LivePage existing;
    switch (livePage(op.pagePublicId)) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        existing = row;
    }
    final after = existing.patched(
      name: op.name,
      isAutoNamed: op.isAutoNamed,
      isAttack: op.isAttack,
    );
    final write = _changed(existing, after);
    if (write.fields.isEmpty) return const OpUnchanged();
    if (_revisionRefusal(op.expectedPageRevision, existing.revision)
        case final refused?) {
      return refused;
    }
    final fields = write.fields;
    return OpApplied(
      writes: [write],
      undo: UndoWithOp(
        PagePatchOp(
          opId: undoId,
          pagePublicId: existing.publicId,
          expectedPageRevision: after.revision,
          name: fields.contains(RowField.name) ? existing.name : null,
          isAutoNamed: fields.contains(RowField.isAutoNamed)
              ? existing.isAutoNamed ?? false
              : null,
          isAttack: fields.contains(RowField.isAttack)
              ? existing.isAttack
              : null,
        ),
      ),
    );
  }

  ApplyResult pageSettingsPatch(PageSettingsPatchOp op) {
    if (livePage(op.pagePublicId) case _Refused(:final refusal)) return refusal;
    final ReadablePageSettings existing;
    switch (rows.settingsOf(op.pagePublicId)) {
      case null:
        return _failed(FailureCode.invalidPageContentCount);
      case UnreadablePageSettings(:final RowKey key):
        return OpRefused(UnreadableTarget(key));
      case final ReadablePageSettings readable:
        existing = readable;
    }
    if (existing.settings == op.settings) return const OpUnchanged();
    if (_revisionRefusal(op.expectedPageSettingsRevision, existing.revision)
        case final refused?) {
      return refused;
    }
    final after = existing.withSettings(op.settings);
    return OpApplied(
      writes: [_changed(existing, after)],
      undo: switch (existing.settings) {
        final settings? => UndoWithOp(
          PageSettingsPatchOp(
            opId: undoId,
            pagePublicId: op.pagePublicId,
            settings: settings,
            expectedPageSettingsRevision: after.revision,
          ),
        ),
        null => const UndoUnavailable(),
      },
    );
  }

  OpRefused? targetPageRefusal(String pagePublicId) =>
      switch (rows.page(pagePublicId)) {
        null => _failed(FailureCode.pageStrategyMismatch),
        PageRow() => holdingPageRefusal(pagePublicId),
      };

  OpRefused? holdingPageRefusal(String pagePublicId) =>
      switch (rows.page(pagePublicId)) {
        LivePage() || UnreadablePage(trashed: false) => null,
        null ||
        TrashedPage() ||
        UnreadablePage(trashed: true) => _failed(FailureCode.pageDeleted),
        UnreadablePage(:final RowKey key) => OpRefused(UnreadableTarget(key)),
      };

  ApplyResult elementAdd(ElementAddOp op) {
    if (targetPageRefusal(op.pagePublicId) case final refused?) return refused;
    if (_elementTypeRefusal(op.payload) case final refused?) return refused;
    final existing = rows.element(op.elementPublicId);
    if (existing == null) {
      final added = _elementRow(
        publicId: op.elementPublicId,
        pagePublicId: op.pagePublicId,
        payload: op.payload,
        sortIndex: op.sortIndex,
        revision: 1,
      );
      return OpApplied(writes: [RowAdded(added)], undo: _undoAdd(added, 1));
    }
    if (holdingPageRefusal(existing.pagePublicId) case final refused?) {
      return refused;
    }
    switch (existing) {
      case UnreadableElement(:final RowKey key):
        return OpRefused(UnreadableTarget(key));
      case DeletedElement(
        :final payload,
        :final revision,
        :final unknownFields,
      ):
        final kept = _keptStoredFields(payload, op.payload);
        if (kept != op.payload && exceedsSizePolicy(kept.toJson())) {
          return _failed(FailureCode.invalidPayload);
        }
        if (_revisionRefusal(op.expectedElementRevision, revision)
            case final refused?) {
          return refused;
        }
        final restored = _elementRow(
          publicId: existing.publicId,
          pagePublicId: op.pagePublicId,
          payload: kept,
          sortIndex: op.sortIndex,
          revision: revision + 1,
          unknownFields: unknownFields,
        );
        return OpApplied(
          writes: [_changed(existing, restored)],
          undo: _undoAdd(restored, revision + 1),
        );
      case LiveElement(:final payload, :final sortIndex):
        final kept = _keptStoredFields(payload, op.payload);
        if (kept != op.payload && exceedsSizePolicy(kept.toJson())) {
          return _failed(FailureCode.invalidPayload);
        }
        final identical =
            existing.pagePublicId == op.pagePublicId &&
            payload == kept &&
            sortIndex == op.sortIndex;
        return identical
            ? const OpUnchanged()
            : _rejected(RejectionReason.alreadyExists);
    }
  }

  Undo _undoAdd(ElementRow added, int revision) => UndoWithOp(
    ElementDeleteOp(
      opId: undoId,
      elementPublicId: added.publicId,
      pagePublicId: added.pagePublicId,
      expectedElementRevision: revision,
    ),
  );

  ApplyResult elementDelete(ElementDeleteOp op) {
    final existing = rows.element(op.elementPublicId);
    if (existing == null || existing is DeletedElement) {
      return const OpUnchanged();
    }
    if (existing case UnreadableElement(:final RowKey key)) {
      return OpRefused(UnreadableTarget(key));
    }
    if (holdingPageRefusal(existing.pagePublicId) case final refused?) {
      return refused;
    }
    final LiveElement live;
    switch (existing) {
      case DeletedElement():
        return const OpUnchanged();
      case UnreadableElement(:final RowKey key):
        return OpRefused(UnreadableTarget(key));
      case final LiveElement row:
        live = row;
    }
    if (!op.lastWriterWins) {
      if (_revisionRefusal(op.expectedElementRevision, live.revision)
          case final refused?) {
        return refused;
      }
    }
    final after = DeletedElement(
      publicId: live.publicId,
      pagePublicId: live.pagePublicId,
      payload: live.payload,
      sortIndex: live.sortIndex,
      revision: live.revision + 1,
      unknownFields: live.unknownFields,
    );
    return OpApplied(
      writes: [_changed(live, after)],
      undo: UndoWithOp(
        ElementAddOp(
          opId: undoId,
          elementPublicId: live.publicId,
          pagePublicId: live.pagePublicId,
          payload: live.payload,
          sortIndex: live.sortIndex,
          expectedElementRevision: after.revision,
        ),
      ),
    );
  }

  _Target<LiveElement> editableElement(String elementPublicId) {
    final existing = rows.element(elementPublicId);
    if (existing == null) return _Refused(_rejected(RejectionReason.notFound));
    if (holdingPageRefusal(existing.pagePublicId) case final refused?) {
      return _Refused(refused);
    }
    return switch (existing) {
      DeletedElement() => _Refused(_rejected(RejectionReason.deleted)),
      UnreadableElement(:final RowKey key) => _Refused(
        OpRefused(UnreadableTarget(key)),
      ),
      final LiveElement live => _Found(live),
    };
  }

  ApplyResult elementReorder(ElementReorderOp op) {
    final LiveElement existing;
    switch (editableElement(op.elementPublicId)) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        existing = row;
    }
    if (existing.sortIndex == op.sortIndex) return const OpUnchanged();
    if (_revisionRefusal(op.expectedElementRevision, existing.revision)
        case final refused?) {
      return refused;
    }
    final after = LiveElement(
      publicId: existing.publicId,
      pagePublicId: existing.pagePublicId,
      payload: existing.payload,
      sortIndex: op.sortIndex,
      revision: existing.revision + 1,
      unknownFields: existing.unknownFields,
    );
    return OpApplied(
      writes: [_changed(existing, after)],
      undo: UndoWithOp(
        ElementReorderOp(
          opId: undoId,
          elementPublicId: existing.publicId,
          pagePublicId: existing.pagePublicId,
          sortIndex: existing.sortIndex,
          expectedElementRevision: after.revision,
        ),
      ),
    );
  }

  ApplyResult elementPatch(ElementPatchOp op) {
    final LiveElement existing;
    switch (editableElement(op.elementPublicId)) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        existing = row;
    }
    final stored = existing.payload;
    final requested = op.merge;
    final targetPage = op.pagePublicId;
    if (requested != null && targetPage != null) {
      if (targetPageRefusal(targetPage) case final refused?) return refused;
    }
    final merge =
        requested != null &&
            (targetPage == null || targetPage == existing.pagePublicId)
        ? requested
        : null;
    if (requested != null && !mergeShapeIsValid(requested)) {
      return _failed(FailureCode.invalidOp);
    }
    var checkRevision = merge == null;
    var payload = stored;
    if (op.payload case final sent?) {
      if (_elementTypeRefusal(sent) case final refused?) return refused;
      if (sent.kind != stored.kind) {
        return _failed(FailureCode.elementTypePayloadKindMismatch);
      }
      var written = sent;
      if (merge != null) {
        switch (mergeElementPayload(stored, sent, merge)) {
          case MergeConflict():
            return _rejected(RejectionReason.fieldConflict);
          case Merged(:final value):
            if (exceedsSizePolicy(value.toJson())) {
              return _failed(FailureCode.invalidPayload);
            }
            written = value;
          case WriteWhole():
            checkRevision = true;
        }
      }
      payload = _keptStoredFields(stored, written);
      if (payload != written && exceedsSizePolicy(payload.toJson())) {
        return _failed(FailureCode.invalidPayload);
      }
    }
    if (!checkRevision &&
        placeChanged(merge, existing.sortIndex, op.sortIndex)) {
      return _rejected(RejectionReason.fieldConflict);
    }
    final sortIndex = op.sortIndex;
    final movesPlace =
        sortIndex != null &&
        (checkRevision || merge!.fields.contains(placeField));
    if (targetPage != null && merge == null) {
      if (targetPageRefusal(targetPage) case final refused?) return refused;
    }
    final after = _elementRow(
      publicId: existing.publicId,
      pagePublicId: targetPage ?? existing.pagePublicId,
      payload: payload,
      sortIndex: movesPlace ? sortIndex : existing.sortIndex,
      revision: existing.revision + 1,
      unknownFields: existing.unknownFields,
    );
    final write = _changed(existing, after);
    if (write.fields.isEmpty && write.dataFields.isEmpty) {
      return const OpUnchanged();
    }
    if (checkRevision) {
      if (_revisionRefusal(op.expectedElementRevision, existing.revision)
          case final refused?) {
        return refused;
      }
    }
    return OpApplied(writes: [write], undo: _undoElementPatch(existing, write));
  }

  Undo _undoElementPatch(LiveElement before, RowChanged write) {
    if (write.dataFields.any(
      (field) =>
          _isLaterField(before.payload.kind, field) &&
          !before.payload.data.containsKey(field),
    )) {
      return const UndoUnavailable();
    }
    final fields = write.fields;
    final movedPlace = fields.contains(RowField.sortIndex);
    final payloadChanged =
        write.dataFields.isNotEmpty ||
        fields.contains(RowField.payloadVersion) ||
        fields.contains(RowField.kind);
    final mergeFields = [
      if (payloadChanged) ...write.dataFields.toList()..sort(),
      if (movedPlace) placeField,
    ];
    return UndoWithOp(
      ElementPatchOp(
        opId: undoId,
        elementPublicId: before.publicId,
        expectedElementRevision: before.revision + 1,
        pagePublicId: fields.contains(RowField.page)
            ? before.pagePublicId
            : null,
        payload: payloadChanged ? before.payload : null,
        sortIndex: movedPlace ? before.sortIndex : null,
        merge: mergeFields.isEmpty ? null : FieldMerge(fields: mergeFields),
      ),
    );
  }

  ApplyResult lineupGroupAdd(LineupGroupAddOp op) {
    if (targetPageRefusal(op.pagePublicId) case final refused?) return refused;
    if (_lineupPayloadRefusal(op.payload, op.lineupPublicId)
        case final refused?) {
      return refused;
    }
    final existing = rows.lineupGroup(op.lineupPublicId);
    if (existing == null) {
      if (_overlapRefusal(op.pagePublicId, null, op.payload)
          case final refused?) {
        return refused;
      }
      final added = LiveLineupGroup(
        strategyPublicId: strategy.publicId,
        publicId: op.lineupPublicId,
        pagePublicId: op.pagePublicId,
        payload: op.payload,
        sortIndex: op.sortIndex,
        revision: 1,
      );
      return OpApplied(writes: [RowAdded(added)], undo: _undoGroupAdd(added));
    }
    if (holdingPageRefusal(existing.pagePublicId) case final refused?) {
      return refused;
    }
    switch (existing) {
      case UnreadableLineupGroup(:final RowKey key):
        return OpRefused(UnreadableTarget(key));
      case DeletedLineupGroup(:final revision, :final unknownFields):
        if (_revisionRefusal(op.expectedLineupRevision, revision)
            case final refused?) {
          return refused;
        }
        if (_overlapRefusal(op.pagePublicId, existing.publicId, op.payload)
            case final refused?) {
          return refused;
        }
        final restored = LiveLineupGroup(
          strategyPublicId: strategy.publicId,
          publicId: existing.publicId,
          pagePublicId: op.pagePublicId,
          payload: op.payload,
          sortIndex: op.sortIndex,
          revision: revision + 1,
          unknownFields: unknownFields,
        );
        return OpApplied(
          writes: [_changed(existing, restored)],
          undo: _undoGroupAdd(restored),
        );
      case LiveLineupGroup(:final pagePublicId, :final payload):
        final identical =
            pagePublicId == op.pagePublicId && payload == op.payload;
        return identical
            ? const OpUnchanged()
            : _rejected(RejectionReason.alreadyExists);
    }
  }

  Undo _undoGroupAdd(LiveLineupGroup added) => UndoWithOp(
    LineupGroupDeleteOp(
      opId: undoId,
      lineupPublicId: added.publicId,
      pagePublicId: added.pagePublicId,
      expectedLineupRevision: added.revision,
    ),
  );

  ApplyResult lineupGroupDelete(LineupGroupDeleteOp op) {
    final LiveLineupGroup existing;
    switch (rows.lineupGroup(op.lineupPublicId)) {
      case null || DeletedLineupGroup():
        return const OpUnchanged();
      case UnreadableLineupGroup(:final RowKey key):
        return OpRefused(UnreadableTarget(key));
      case final LiveLineupGroup live:
        existing = live;
    }
    if (holdingPageRefusal(existing.pagePublicId) case final refused?) {
      return refused;
    }
    if (!op.lastWriterWins) {
      if (_revisionRefusal(op.expectedLineupRevision, existing.revision)
          case final refused?) {
        return refused;
      }
    }
    final after = DeletedLineupGroup(
      strategyPublicId: strategy.publicId,
      publicId: existing.publicId,
      pagePublicId: existing.pagePublicId,
      payload: existing.payload,
      sortIndex: existing.sortIndex,
      revision: existing.revision + 1,
      unknownFields: existing.unknownFields,
    );
    return OpApplied(
      writes: [_changed(existing, after)],
      undo: UndoWithOp(
        LineupGroupAddOp(
          opId: undoId,
          lineupPublicId: existing.publicId,
          pagePublicId: existing.pagePublicId,
          payload: existing.payload,
          sortIndex: existing.sortIndex,
          expectedLineupRevision: after.revision,
        ),
      ),
    );
  }

  _Target<LiveLineupGroup> editableGroup(String lineupPublicId) {
    final existing = rows.lineupGroup(lineupPublicId);
    if (existing == null) return _Refused(_rejected(RejectionReason.notFound));
    if (holdingPageRefusal(existing.pagePublicId) case final refused?) {
      return _Refused(refused);
    }
    return switch (existing) {
      UnreadableLineupGroup(:final RowKey key) => _Refused(
        OpRefused(UnreadableTarget(key)),
      ),
      DeletedLineupGroup() => _Refused(_rejected(RejectionReason.deleted)),
      final LiveLineupGroup live => _Found(live),
    };
  }

  ApplyResult lineupGroupReorder(LineupGroupReorderOp op) {
    final LiveLineupGroup existing;
    switch (editableGroup(op.lineupPublicId)) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        existing = row;
    }
    if (existing.sortIndex == op.sortIndex) return const OpUnchanged();
    if (_revisionRefusal(op.expectedLineupRevision, existing.revision)
        case final refused?) {
      return refused;
    }
    final after = LiveLineupGroup(
      strategyPublicId: strategy.publicId,
      publicId: existing.publicId,
      pagePublicId: existing.pagePublicId,
      payload: existing.payload,
      sortIndex: op.sortIndex,
      revision: existing.revision + 1,
      unknownFields: existing.unknownFields,
    );
    return OpApplied(
      writes: [_changed(existing, after)],
      undo: UndoWithOp(
        LineupGroupReorderOp(
          opId: undoId,
          lineupPublicId: existing.publicId,
          pagePublicId: existing.pagePublicId,
          sortIndex: existing.sortIndex,
          expectedLineupRevision: after.revision,
        ),
      ),
    );
  }

  ApplyResult lineupGroupPatch(LineupGroupPatchOp op) {
    final LiveLineupGroup existing;
    switch (editableGroup(op.lineupPublicId)) {
      case _Refused(:final refusal):
        return refusal;
      case _Found(:final row):
        existing = row;
    }
    final merge = op.merge;
    if (merge != null && !mergeShapeIsValid(merge)) {
      return _failed(FailureCode.invalidOp);
    }
    var checkRevision = merge == null;
    var payload = existing.payload;
    if (op.payload case final sent?) {
      if (_lineupPayloadRefusal(sent, existing.publicId) case final refused?) {
        return refused;
      }
      payload = sent;
      if (merge != null) {
        switch (mergeLineupPayload(existing.payload, sent, merge)) {
          case MergeConflict():
            return _rejected(RejectionReason.fieldConflict);
          case Merged(:final value):
            if (exceedsSizePolicy(value.toJson())) {
              return _failed(FailureCode.invalidPayload);
            }
            if (_lineupPayloadRefusal(value, existing.publicId) != null) {
              return _rejected(RejectionReason.mergeInvalid);
            }
            payload = value;
          case WriteWhole():
            checkRevision = true;
        }
      }
    }
    if (!checkRevision &&
        placeChanged(merge, existing.sortIndex, op.sortIndex)) {
      return _rejected(RejectionReason.fieldConflict);
    }
    final sortIndex = op.sortIndex;
    final movesPlace =
        sortIndex != null &&
        (checkRevision || merge!.fields.contains(placeField));
    if (op.pagePublicId case final pagePublicId?) {
      if (rows.page(pagePublicId) == null) {
        return _failed(FailureCode.pageStrategyMismatch);
      }
      if (pagePublicId != existing.pagePublicId) {
        return _failed(FailureCode.lineupPageMismatch);
      }
    }
    final after = LiveLineupGroup(
      strategyPublicId: strategy.publicId,
      publicId: existing.publicId,
      pagePublicId: existing.pagePublicId,
      payload: payload,
      sortIndex: movesPlace ? sortIndex : existing.sortIndex,
      revision: existing.revision + 1,
      unknownFields: existing.unknownFields,
    );
    final write = _changed(existing, after);
    if (write.fields.isEmpty && write.dataFields.isEmpty) {
      return const OpUnchanged();
    }
    if (checkRevision) {
      if (_revisionRefusal(op.expectedLineupRevision, existing.revision)
          case final refused?) {
        return refused;
      }
    }
    if (payload != existing.payload) {
      if (_overlapRefusal(existing.pagePublicId, existing.publicId, payload)
          case final refused?) {
        return refused;
      }
    }
    return OpApplied(
      writes: [write],
      undo: UndoWithOp(_undoGroupPatch(existing, write)),
    );
  }

  LineupGroupPatchOp _undoGroupPatch(LiveLineupGroup before, RowChanged write) {
    final movedPlace = write.fields.contains(RowField.sortIndex);
    final payloadChanged =
        write.dataFields.isNotEmpty ||
        write.fields.contains(RowField.payloadVersion);
    final byItem = write.dataFields.every(
      (field) => lineupField(field) != null,
    );
    final mergeFields = [
      if (payloadChanged) ...write.dataFields.toList()..sort(),
      if (movedPlace) placeField,
    ];
    return LineupGroupPatchOp(
      opId: undoId,
      lineupPublicId: before.publicId,
      expectedLineupRevision: before.revision + 1,
      payload: payloadChanged ? before.payload : null,
      sortIndex: movedPlace ? before.sortIndex : null,
      merge: mergeFields.isEmpty || !byItem
          ? null
          : FieldMerge(fields: mergeFields),
    );
  }

  OpRefused? _overlapRefusal(
    String pagePublicId,
    String? selfPublicId,
    LineupGroupPayload payload,
  ) {
    final items = lineupGroupItems(payload.data);
    for (final other in rows.lineupGroupsOn(pagePublicId)) {
      if (other is! LiveLineupGroup || other.publicId == selfPublicId) {
        continue;
      }
      if (lineupGroupItems(other.payload.data).any(items.contains)) {
        return _failed(FailureCode.invalidLineupPayloadData);
      }
    }
    return null;
  }

  OpRefused? _uncopyable(String pagePublicId) {
    for (final element in rows.elementsOn(pagePublicId)) {
      if (element case UnreadableElement(
        :final key,
        :final stored,
      ) when stored is! Map<String, Object?>) {
        return OpRefused(UnreadableTarget(key));
      }
    }
    for (final group in rows.lineupGroupsOn(pagePublicId)) {
      if (group case UnreadableLineupGroup(:final RowKey key)) {
        return OpRefused(UnreadableTarget(key));
      }
    }
    return null;
  }

  RowWrite? _placed(LivePage page, int index) {
    final name = page.isAutoNamed == true ? 'Page ${index + 1}' : page.name;
    if (page.sortIndex == index && page.name == name) return null;
    return _changed(page, page.placed(name: name, sortIndex: index));
  }
}

int _clamp(int index, int maximum) => math.max(0, math.min(index, maximum));

sealed class _Slot {
  const _Slot();

  String get publicId;

  int get sortIndex;
}

final class _LiveSlot extends _Slot {
  const _LiveSlot(this.page);

  final LivePage page;

  @override
  String get publicId => page.publicId;

  @override
  int get sortIndex => page.sortIndex;
}

final class _HeldSlot extends _Slot {
  const _HeldSlot(this.page, this.sortIndex);

  final UnreadablePage page;

  @override
  final int sortIndex;

  @override
  String get publicId => page.publicId;
}

final class _NewSlot extends _Slot {
  const _NewSlot();

  @override
  String get publicId => '';

  @override
  int get sortIndex => -1;
}

ValueEdit<T> _restoring<T extends Object>(T? value) => switch (value) {
  final T value? => SetValue(value),
  null => ClearValue<T>(),
};

ElementRow _elementRow({
  required String publicId,
  required String pagePublicId,
  required ElementPayload payload,
  required int sortIndex,
  required int revision,
  Map<String, Object?> unknownFields = const {},
}) => payload.isReadable
    ? LiveElement(
        publicId: publicId,
        pagePublicId: pagePublicId,
        payload: payload,
        sortIndex: sortIndex,
        revision: revision,
        unknownFields: unknownFields,
      )
    : UnreadableElement(
        publicId: publicId,
        pagePublicId: pagePublicId,
        stored: {
          ...unknownFields,
          'publicId': publicId,
          'pagePublicId': pagePublicId,
          'payload': payload.toJson(),
          'sortIndex': sortIndex,
          'revision': revision,
          'deleted': false,
        },
        problem: 'a payload version from a newer build',
      );

OpRefused? _elementTypeRefusal(ElementPayload payload) {
  final elementType = payload.data['elementType'];
  if (elementType is String && elementType != payload.kind.name) {
    return _failed(FailureCode.elementTypePayloadKindMismatch);
  }
  return null;
}

const _placedKinds = {
  ElementKind.agent,
  ElementKind.ability,
  ElementKind.text,
  ElementKind.image,
  ElementKind.utility,
};

const _laterElementFields = <(String, Set<ElementKind>)>[
  ('caption', _placedKinds),
  ('wallPath', {ElementKind.ability}),
  ('mapDoor', {ElementKind.utility}),
  ('isZone', {ElementKind.utility}),
];

bool _isLaterField(ElementKind kind, String field) => _laterElementFields.any(
  (entry) => entry.$1 == field && entry.$2.contains(kind),
);

ElementPayload _keptStoredFields(ElementPayload stored, ElementPayload next) {
  final data = {...next.data};
  final assetId = stored.data['assetId'];
  if (assetId is String && !next.data.containsKey('assetId')) {
    data['assetId'] = assetId;
  }
  for (final (field, kinds) in _laterElementFields) {
    if (kinds.contains(next.kind) &&
        stored.data.containsKey(field) &&
        !data.containsKey(field)) {
      data[field] = stored.data[field];
    }
  }
  final unknownFields = {...stored.unknownFields, ...next.unknownFields};
  if (data.length == next.data.length &&
      unknownFields.length == next.unknownFields.length) {
    return next;
  }
  return ElementPayload(
    kind: next.kind,
    payloadVersion: next.payloadVersion,
    data: data,
    unknownFields: unknownFields,
  );
}

OpRefused? _lineupPayloadRefusal(
  LineupGroupPayload payload,
  String lineupPublicId,
) {
  if (payload.payloadVersion != lineupGroupPayloadVersion) {
    return _failed(FailureCode.invalidLineupPayloadVersion);
  }
  final data = payload.data;
  final id = data['id'];
  if (id is! String || id.isEmpty || id != lineupPublicId) {
    return _failed(FailureCode.invalidLineupPayloadData);
  }
  final origins = _idsOfEntries(data['origins'], 'agent');
  final landings = _idsOfEntries(data['landings'], 'ability');
  final links = _idsOfEntries(data['links'], null);
  if (origins == null || landings == null || links == null) {
    return _failed(FailureCode.invalidLineupPayloadData);
  }
  final linkList = lineupItems(data, 'links');
  if (linkList.isEmpty) return _failed(FailureCode.invalidLineupPayloadData);
  for (final link in linkList) {
    if (!origins.contains(link['originId']) ||
        !landings.contains(link['landingId'])) {
      return _failed(FailureCode.invalidLineupPayloadData);
    }
  }
  return null;
}

Set<String>? _idsOfEntries(Object? entries, String? markerKey) {
  if (entries is! List<Object?>) return null;
  final ids = <String>{};
  for (final entry in entries) {
    if (entry is! Map<String, Object?>) return null;
    final id = entry['id'];
    if (id is! String || id.isEmpty || !ids.add(id)) return null;
    if (markerKey != null && entry[markerKey] is! Map<String, Object?>) {
      return null;
    }
  }
  return ids;
}

Set<String> lineupGroupItems(Map<String, Object?> data) => {
  for (final (collection, prefix) in const [
    ('origins', 'origin'),
    ('landings', 'landing'),
    ('links', 'link'),
  ])
    for (final item in lineupItems(data, collection))
      if (item['id'] case final String id) '$prefix:$id',
};

RowChanged _changed(Row before, Row after) {
  final fields = <RowField>{};
  var dataFields = <String>{};
  void compare(RowField field, Object? left, Object? right) {
    if (left != right) fields.add(field);
  }

  switch ((before, after)) {
    case (final ReadableStrategy a, final ReadableStrategy b):
      compare(RowField.updatedAt, a.updatedAt, b.updatedAt);
      compare(RowField.name, a.name, b.name);
      compare(RowField.mapData, a.mapData, b.mapData);
      compare(RowField.themeProfileId, a.themeProfileId, b.themeProfileId);
      compare(
        RowField.themeOverridePalette,
        a.themeOverridePalette,
        b.themeOverridePalette,
      );
    case (final ReadablePageRow a, final ReadablePageRow b):
      compare(RowField.name, a.name, b.name);
      compare(RowField.isAutoNamed, a.isAutoNamed, b.isAutoNamed);
      compare(RowField.isAttack, a.isAttack, b.isAttack);
      compare(RowField.sortIndex, a.sortIndex, b.sortIndex);
      compare(RowField.deleted, a is TrashedPage, b is TrashedPage);
    case (final ReadablePageSettings a, final ReadablePageSettings b):
      compare(RowField.settings, a.settings, b.settings);
    case (final ReadableElementRow a, final ReadableElementRow b):
      compare(RowField.page, a.pagePublicId, b.pagePublicId);
      compare(RowField.sortIndex, a.sortIndex, b.sortIndex);
      compare(RowField.deleted, a is DeletedElement, b is DeletedElement);
      compare(RowField.kind, a.payload.kind, b.payload.kind);
      compare(
        RowField.payloadVersion,
        a.payload.payloadVersion,
        b.payload.payloadVersion,
      );
      dataFields = _changedKeys(a.payload.data, b.payload.data);
    case (final ReadableElementRow a, final UnreadableElement b):
      compare(RowField.page, a.pagePublicId, b.pagePublicId);
      fields
        ..add(RowField.kind)
        ..add(RowField.payloadVersion);
    case (final ReadableLineupGroupRow a, final ReadableLineupGroupRow b):
      compare(RowField.page, a.pagePublicId, b.pagePublicId);
      compare(RowField.sortIndex, a.sortIndex, b.sortIndex);
      compare(
        RowField.deleted,
        a is DeletedLineupGroup,
        b is DeletedLineupGroup,
      );
      compare(
        RowField.payloadVersion,
        a.payload.payloadVersion,
        b.payload.payloadVersion,
      );
      dataFields = _changedLineupFields(a.payload.data, b.payload.data);
    case _:
      throw ArgumentError('$before cannot change into $after');
  }
  return RowChanged(
    before: before,
    after: after,
    fields: fields,
    dataFields: dataFields,
  );
}

bool _sameEntry(
  Map<String, Object?> left,
  Map<String, Object?> right,
  String key,
) =>
    left.containsKey(key) == right.containsKey(key) &&
    sameJson(left[key], right[key]);

Set<String> _changedKeys(
  Map<String, Object?> left,
  Map<String, Object?> right,
) => {
  for (final key in {...left.keys, ...right.keys})
    if (!_sameEntry(left, right, key)) key,
};

Set<String> _changedLineupFields(
  Map<String, Object?> left,
  Map<String, Object?> right,
) {
  final changed = <String>{};
  for (final key in {...left.keys, ...right.keys}) {
    if (!lineupCollections.contains(key)) {
      if (!_sameEntry(left, right, key)) changed.add(key);
      continue;
    }
    Map<String, Object?> byId(Map<String, Object?> data) => {
      for (final item in lineupItems(data, key))
        if (item['id'] case final String id) id: item,
    };
    final before = byId(left);
    final after = byId(right);
    for (final id in {...before.keys, ...after.keys}) {
      if (!_sameEntry(before, after, id)) changed.add('$key/$id');
    }
    final kept = [...before.keys.where(after.containsKey)];
    if (!const ListEquality<String>().equals(kept, [
      ...after.keys.where(before.containsKey),
    ])) {
      changed.add(key);
    }
  }
  return changed;
}
