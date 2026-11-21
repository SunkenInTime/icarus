import 'dart:math' as math;

import 'package:collection/collection.dart';

import 'derived_id.dart';
import 'field_merge.dart';
import 'field_rules.dart';
import 'json.dart';
import 'lineup_graph.dart';
import 'ops.dart';
import 'outcome.dart';
import 'page_copy.dart';
import 'payloads.dart';
import 'rows.dart';
import 'strategy_rows.dart';

ApplyResult applyOp(StrategyRows rows, StrategyOp op) {
  final json = op.toJsonView();
  if (!isJson(json) || exceedsSizePolicy(json)) {
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
    switch (source) {
      case UnreadablePage(:final RowKey key):
        return OpRefused(UnreadableTarget(key));
      case LivePage():
        if (_uncopyable(source.publicId) case final refused?) return refused;
      case TrashedPage() || null:
        break;
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
    if (live.whereType<_LiveSlot>().length <= 1) {
      return _failed(FailureCode.invalidOp);
    }
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
      case DeletedElement(:final payload, :final revision):
        final kept = keepStoredFields(payload, op.payload);
        if (kept != op.payload && exceedsSizePolicy(kept.toJsonView())) {
          return _failed(FailureCode.invalidPayload);
        }
        if (_revisionRefusal(op.expectedElementRevision, revision)
            case final refused?) {
          return refused;
        }
        final restored = existing.rewritten(
          deleted: false,
          pagePublicId: op.pagePublicId,
          payload: kept,
          sortIndex: op.sortIndex,
        );
        return OpApplied(
          writes: [_changed(existing, restored)],
          undo: _undoAdd(restored, revision + 1),
        );
      case LiveElement(:final payload, :final sortIndex):
        final kept = keepStoredFields(payload, op.payload);
        if (kept != op.payload && exceedsSizePolicy(kept.toJsonView())) {
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
    final LiveElement live;
    switch (rows.element(op.elementPublicId)) {
      case null || DeletedElement():
        return const OpUnchanged();
      case UnreadableElement(:final RowKey key):
        return OpRefused(UnreadableTarget(key));
      case final LiveElement row:
        live = row;
    }
    if (holdingPageRefusal(live.pagePublicId) case final refused?) {
      return refused;
    }
    if (!op.lastWriterWins) {
      if (_revisionRefusal(op.expectedElementRevision, live.revision)
          case final refused?) {
        return refused;
      }
    }
    final after = live.rewritten(deleted: true);
    return OpApplied(
      writes: [_changed(live, after)],
      undo: UndoWithOp(
        ElementAddOp(
          opId: undoId,
          elementPublicId: live.publicId,
          pagePublicId: live.pagePublicId,
          payload: live.payload,
          sortIndex: live.sortIndex,
          expectedElementRevision: live.revision + 1,
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
    final after = existing.rewritten(deleted: false, sortIndex: op.sortIndex);
    return OpApplied(
      writes: [_changed(existing, after)],
      undo: UndoWithOp(
        ElementReorderOp(
          opId: undoId,
          elementPublicId: existing.publicId,
          pagePublicId: existing.pagePublicId,
          sortIndex: existing.sortIndex,
          expectedElementRevision: existing.revision + 1,
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
            if (exceedsSizePolicy(value.toJsonView())) {
              return _failed(FailureCode.invalidPayload);
            }
            written = value;
          case WriteWhole():
            checkRevision = true;
        }
      }
      payload = keepStoredFields(stored, written);
      if (payload != written && exceedsSizePolicy(payload.toJsonView())) {
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
    final after = existing.rewritten(
      deleted: false,
      pagePublicId: targetPage,
      payload: payload,
      sortIndex: movesPlace ? sortIndex : null,
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
    return OpApplied(
      writes: [write],
      undo: _undoElementPatch(existing, write, whole: checkRevision),
    );
  }

  Undo _undoElementPatch(
    LiveElement before,
    RowChanged write, {
    required bool whole,
  }) {
    final restored = <String, Object?>{...before.payload.data.raw};
    for (final field in write.dataFields) {
      if (before.payload.data.raw.containsKey(field)) continue;
      if (field == pictureIdField) return const UndoUnavailable();
      switch (laterField(before.payload.kind, field)?.empty) {
        case null:
          break;
        case NeverCleared():
          return const UndoUnavailable();
        case ClearedBy(:final value):
          restored[field] = value;
      }
    }
    final fields = write.fields;
    final movedPlace = fields.contains(RowField.sortIndex);
    final payloadChanged =
        write.dataFields.isNotEmpty ||
        fields.contains(RowField.payloadVersion) ||
        fields.contains(RowField.kind);
    final mergeFields = [
      if (payloadChanged)
        ...groupedFields(
          before.payload.kind,
          switch (write.after) {
            ReadableElementRow(:final payload) => payload.data.raw,
            _ => const {},
          },
          restored,
          write.dataFields,
        ),
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
        payload: payloadChanged
            ? elementPayloadAdopting(before.payload, restored)
            : null,
        sortIndex: movedPlace ? before.sortIndex : null,
        merge: whole || mergeFields.isEmpty
            ? null
            : FieldMerge(fields: mergeFields),
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
      case DeletedLineupGroup(:final revision):
        if (_revisionRefusal(op.expectedLineupRevision, revision)
            case final refused?) {
          return refused;
        }
        if (_overlapRefusal(op.pagePublicId, existing.publicId, op.payload)
            case final refused?) {
          return refused;
        }
        final restored = existing.rewritten(
          deleted: false,
          pagePublicId: op.pagePublicId,
          payload: op.payload,
          sortIndex: op.sortIndex,
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

  Undo _undoGroupAdd(ReadableLineupGroupRow added) => UndoWithOp(
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
    final after = existing.rewritten(deleted: true);
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
    final after = existing.rewritten(deleted: false, sortIndex: op.sortIndex);
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
            if (exceedsSizePolicy(value.toJsonView())) {
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
    final after = existing.rewritten(
      deleted: false,
      payload: payload,
      sortIndex: movesPlace ? sortIndex : null,
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
      undo: UndoWithOp(_undoGroupPatch(existing, write, whole: checkRevision)),
    );
  }

  LineupGroupPatchOp _undoGroupPatch(
    LiveLineupGroup before,
    RowChanged write, {
    required bool whole,
  }) {
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
      merge: whole || mergeFields.isEmpty || !byItem
          ? null
          : FieldMerge(fields: mergeFields),
    );
  }

  OpRefused? _overlapRefusal(
    String pagePublicId,
    String? selfPublicId,
    LineupGroupPayload payload,
  ) {
    final items = lineupGroupItems(payload.data.raw);
    for (final other in rows.lineupGroupsOn(pagePublicId)) {
      if (other is! LiveLineupGroup || other.publicId == selfPublicId) {
        continue;
      }
      if (lineupGroupItems(other.payload.data.raw).any(items.contains)) {
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
      ) when stored is! JsonObject) {
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
}) => payload.isReadable
    ? LiveElement(
        publicId: publicId,
        pagePublicId: pagePublicId,
        payload: payload,
        sortIndex: sortIndex,
        revision: revision,
      )
    : UnreadableElement(
        publicId: publicId,
        pagePublicId: pagePublicId,
        stored: {
          'publicId': publicId,
          'pagePublicId': pagePublicId,
          'payload': payload.toJsonView(),
          'sortIndex': sortIndex,
          'revision': revision,
          'deleted': false,
        },
        problem: 'a payload version from a newer build',
        reason: const FromNewerBuild(),
      );

OpRefused? _elementTypeRefusal(ElementPayload payload) {
  final elementType = payload.data.raw['elementType'];
  if (elementType is String && elementType != payload.kind.name) {
    return _failed(FailureCode.elementTypePayloadKindMismatch);
  }
  return null;
}

OpRefused? _lineupPayloadRefusal(
  LineupGroupPayload payload,
  String lineupPublicId,
) => switch (checkLineupPayload(payload, lineupPublicId)) {
  ValidLineupGroup() => null,
  OtherLineupVersion() => _failed(FailureCode.invalidLineupPayloadVersion),
  BrokenLineupGraph() => _failed(FailureCode.invalidLineupPayloadData),
};

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
      dataFields = _changedKeys(a.payload.data.raw, b.payload.data.raw);
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
      dataFields = _changedLineupFields(a.payload.data.raw, b.payload.data.raw);
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
