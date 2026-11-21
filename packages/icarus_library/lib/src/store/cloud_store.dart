part of 'store.dart';

final class _OnDisk {
  _OnDisk({
    required this.entries,
    required this.attempts,
    required this.facts,
    required this.counters,
    required this.groups,
    required this.base,
  });

  final Map<int, QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  StrategyFacts facts;
  Counters counters;
  final Map<String?, EvidenceGroup> groups;
  BaseFacts base;
}

final class _LoadedQueue {
  _LoadedQueue(this.disk, this.current);

  final _OnDisk disk;
  CloudQueue current;
}

final class _PutEntry extends _Write {
  const _PutEntry(super.area, this.entry);

  final QueueEntry entry;
}

final class _PutAttempt extends _Write {
  const _PutAttempt(super.area, this.attempt);

  final AttemptFact attempt;
}

final class _PutFacts extends _Write {
  const _PutFacts(super.area, this.facts);

  final StrategyFacts facts;
}

final class _PutCounters extends _Write {
  const _PutCounters(super.area, this.counters);

  final Counters counters;
}

final class _PutGroup extends _Write {
  const _PutGroup(super.area, this.page, this.group);

  final String? page;
  final EvidenceGroup group;
}

sealed class _QueueLoad {
  const _QueueLoad();
}

final class _QueueLoaded extends _QueueLoad {
  const _QueueLoaded(this.queue);

  final _LoadedQueue queue;
}

final class _QueueNotRead extends _QueueLoad {
  const _QueueNotRead(this.failure);

  final StorageFailure failure;
}

final class _QueueRefused extends _QueueLoad {
  const _QueueRefused(this.refusal);

  final CommitRefusal refusal;
}

sealed class _CloudOpen {
  const _CloudOpen();
}

final class _CloudReady extends _CloudOpen {
  const _CloudReady(this.strategy, this.header, this.queue);

  final LoadedStrategy strategy;
  final ReadableStrategy header;
  final _LoadedQueue queue;
}

final class _CloudRefused extends _CloudOpen {
  const _CloudRefused(this.refusal);

  final CommitRefusal refusal;
}

final class _CloudUnread extends _CloudOpen {
  const _CloudUnread(this.failure);

  final StorageFailure failure;
}

String _groupName(String? page) => switch (page) {
  null => const HeaderReadName().name,
  final page => PageReadName(digestOf(page)).name,
};

int _highest(Iterable<int> numbers) =>
    numbers.fold(0, (highest, number) => number > highest ? number : highest);

PageTally _tallyOn(StrategyRowSet rows, String pageId) {
  var tally = PageTally.empty;
  for (final row in rows.elementsOn(pageId)) {
    tally = tally.plus(row, 1);
  }
  for (final row in rows.lineupGroupsOn(pageId)) {
    tally = tally.plusGroup(row, 1);
  }
  return tally;
}

KeptInCloud _syncOf(CloudQueue queue, DateTime now) => KeptInCloud(
  Tally.of(queue, now),
  QueuedRows.of([for (final entry in queue.entries) entry.place]),
);

Map<String?, EvidenceGroup> _groupsTouched(
  BaseFacts base,
  Iterable<String?> pages,
) {
  final wanted = pages.toSet();
  return {
    for (final MapEntry(:key, :value) in evidenceGroups(base).entries)
      if (wanted.contains(key)) key: value,
  };
}

extension _CloudStore on LibraryStore {
  Stored<Change> _cloudChange(_Write write) {
    StorageFailed<Change> wouldNot(String name, String problem) =>
        StorageFailed(WouldNotReadBack(write.area, name, problem));
    Stored<Change> checked(
      String name,
      Map<String, Object?> json,
      bool Function(String text) readsBack,
    ) => switch (encodeJson(json)) {
      NotEncoded(:final problem) => wouldNot(name, problem),
      Encoded(:final text) when readsBack(text) => Done(
        Put(write.area, name, text),
      ),
      Encoded() => wouldNot(name, 'does not read back as written'),
    };
    return switch (write) {
      _PutEntry(:final entry) => checked(
        PendingName(entry.place).name,
        entryToJson(entry),
        (text) => entryFromText(entry.place, text) == entry,
      ),
      _PutAttempt(:final attempt) => checked(
        AttemptName(attempt.number).name,
        attemptToJson(attempt),
        (text) => switch (attemptFromText(attempt.number, text)) {
          CloudRowRead(:final value) => value == attempt,
          CloudRowUnreadable() => false,
        },
      ),
      _PutFacts(:final facts) => checked(
        const CloudName().name,
        factsToJson(facts),
        (text) => switch (factsFromText(text)) {
          CloudRowRead(:final value) => value == facts,
          CloudRowUnreadable() => false,
        },
      ),
      _PutCounters(:final counters) => checked(
        const CountersName().name,
        countersToJson(counters),
        (text) => switch (countersFromText(text)) {
          CloudRowRead(:final value) => value == counters,
          CloudRowUnreadable() => false,
        },
      ),
      _PutGroup(:final page, :final group) => checked(
        _groupName(page),
        groupToJson(page, group),
        (text) => switch (groupFromText(text, header: page == null)) {
          CloudRowRead(value: (final readPage, final readGroup)) =>
            readPage == page && readGroup == group,
          CloudRowUnreadable() => false,
        },
      ),
      _ => throw StateError('$write is not a cloud row'),
    };
  }

  Future<_QueueLoad> _queueOf(LoadedStrategy strategy) async {
    if (_queues[strategy.digest] case final loaded?) {
      return _QueueLoaded(loaded);
    }
    final area = strategy.area;
    final storeArea = StrategyArea(strategy.digest);
    _QueueRefused unreadable(String name, String problem) =>
        _QueueRefused(CloudStateNotReadable(strategy.refOf(name), problem));
    final StrategyFacts facts;
    switch (await _lease.read(area, const CloudName().name)) {
      case KeyNotRead(:final failure):
        return _QueueNotRead(failure);
      case KeyMissing():
        return _QueueRefused(
          NotACloudStrategy(strategy.strategyId ?? strategy.digest),
        );
      case KeyHeld(:final value):
        switch (factsFromText(value)) {
          case CloudRowRead(:final value):
            facts = value;
          case CloudRowUnreadable(:final problem):
            return unreadable(const CloudName().name, problem);
        }
    }
    var counters = const Counters(nextAttempt: 1, nextRead: 1);
    switch (await _lease.read(area, const CountersName().name)) {
      case KeyNotRead(:final failure):
        return _QueueNotRead(failure);
      case KeyMissing():
        break;
      case KeyHeld(:final value):
        switch (countersFromText(value)) {
          case CloudRowRead(:final value):
            counters = value;
          case CloudRowUnreadable(:final problem):
            return unreadable(const CountersName().name, problem);
        }
    }
    final stored = <(int, String)>[];
    switch (await _lease.entries(area, pendingPrefix)) {
      case StorageFailed(:final failure):
        return _QueueNotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          if (readName(storeArea, key) case PendingName(:final place)) {
            stored.add((place, value));
          }
        }
    }
    final attempts = <int, AttemptFact>{};
    switch (await _lease.entries(area, attemptPrefix)) {
      case StorageFailed(:final failure):
        return _QueueNotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          if (readName(storeArea, key) case AttemptName(:final number)) {
            switch (attemptFromText(number, value)) {
              case CloudRowRead(:final value):
                attempts[number] = value;
              case CloudRowUnreadable(:final problem):
                return unreadable(key, problem);
            }
          }
        }
    }
    final groups = <String?, EvidenceGroup>{};
    switch (await _lease.entries(area, readPrefix)) {
      case StorageFailed(:final failure):
        return _QueueNotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          final name = readName(storeArea, key);
          final header = name is HeaderReadName;
          if (name is! HeaderReadName && name is! PageReadName) continue;
          switch (groupFromText(value, header: header)) {
            case CloudRowRead(value: (final page, final group))
                when page == null ||
                    (name is PageReadName && namesId(name.digest, page)):
              groups[page] = group;
            case CloudRowRead():
              return unreadable(key, 'evidence kept under another page');
            case CloudRowUnreadable(:final problem):
              return unreadable(key, problem);
          }
        }
    }
    final entries = entriesFrom(stored);
    final base = baseFrom(groups);
    final pending = entries.whereType<PendingOp>();
    final nextAttempt = [
      counters.nextAttempt,
      _highest(attempts.keys) + 1,
      for (final entry in pending) entry.retriedAfter + 1,
      facts.accessLostAt + 1,
      facts.accessConfirmedAt + 1,
      if (facts.upgradeTold case UpgradeToldTo(:final attempt)) attempt + 1,
    ].fold(1, (most, next) => next > most ? next : most);
    final nextRead = [
      counters.nextRead,
      base.lastRead + 1,
      for (final entry in pending)
        if (entry.answer
            case AnsweredApplied(:final afterRead) ||
                AnsweredRefused(:final afterRead))
          afterRead + 1,
    ].fold(1, (most, next) => next > most ? next : most);
    final onDisk = CloudQueue(
      entries: entries,
      attempts: attempts,
      nextAttempt: nextAttempt,
      nextRead: nextRead,
      base: base,
      strategy: facts,
      session: QueueSession.start(_build),
    );
    final current = switch (transition(
      onDisk,
      AppRestarted(build: _build),
      now: _clock(),
    )) {
      Stepped(:final queue) => queue,
      NotApplicable() => onDisk,
    };
    final loaded = _LoadedQueue(
      _OnDisk(
        entries: {for (final entry in entries) entry.place: entry},
        attempts: attempts,
        facts: facts,
        counters: counters,
        groups: groups,
        base: base,
      ),
      current,
    );
    _queues[strategy.digest] = loaded;
    if (_summaries[strategy.digest] case final summary?) {
      _keepInMemory(
        strategy.digest,
        summary.withSync(_syncOf(current, _clock())),
      );
    }
    return _QueueLoaded(loaded);
  }

  Future<_CloudOpen> _openCloud(String strategyPublicId) async {
    final LoadedStrategy strategy;
    switch (await _strategy(strategyPublicId)) {
      case Found(:final value):
        strategy = value;
      case NotFound():
        return _CloudRefused(NoSuchStrategy(strategyPublicId));
      case NotRead(:final failure):
        return _CloudUnread(failure);
      case InUnreadableStrategy(:final listing):
        return _CloudRefused(StrategyNotReadable(listing.ref));
    }
    final ReadableStrategy header;
    switch (strategy.header) {
      case HeaderPlaced(row: final ReadableStrategy row):
        header = row;
      case HeaderPlaced(row: final UnreadableStrategy row):
        return _CloudRefused(UnreadableRowInTheWay(row));
      case HeaderUnplaced() || HeaderAbsent():
        return _CloudRefused(NoSuchStrategy(strategyPublicId));
    }
    if (strategy.keeping == Keeping.here) {
      return _CloudRefused(NotACloudStrategy(strategyPublicId));
    }
    return switch (await _queueOf(strategy)) {
      _QueueLoaded(:final queue) => _CloudReady(strategy, header, queue),
      _QueueNotRead(:final failure) => _CloudUnread(failure),
      _QueueRefused(:final refusal) => _CloudRefused(refusal),
    };
  }

  StrategyRowSet _baseRows(LoadedStrategy strategy, ReadableStrategy header) {
    final elements = <ElementRow>[];
    final groups = <LineupGroupRow>[];
    for (final page in strategy.pages) {
      if (strategy.loadedPage(digestOf(page.publicId)) case final loaded?) {
        elements.addAll(loaded.elements.values);
        groups.addAll(loaded.lineupGroups.values);
      }
    }
    return StrategyRowSet(
      strategy: header,
      pages: strategy.pages,
      settings: strategy.allSettings,
      elements: elements,
      lineupGroups: groups,
    );
  }

  ReadableStrategy? _headerOf(LoadedStrategy strategy) =>
      switch (strategy.header) {
        HeaderPlaced(row: final ReadableStrategy row) => row,
        _ => null,
      };

  Future<Stored<Visible>> _visibleFor(
    LoadedStrategy strategy,
    CloudQueue queue,
    Pages pages,
  ) async {
    final header = _headerOf(strategy);
    if (header == null) {
      return const StorageFailed(StoreStopped(StoreClosed()));
    }
    final digests = switch (pages) {
      AllPages() => strategy.pageDigests,
      SomePages() => {
        for (final page in pagesToLoad(queue, pages))
          if (strategy.hasPageRow(digestOf(page))) digestOf(page),
      },
    };
    if (await _loadPages(strategy, digests) case StorageFailed(
      :final failure,
    )) {
      return StorageFailed(failure);
    }
    return Done(visibleOver(_baseRows(strategy, header), queue, pages));
  }

  (List<_Write>, void Function()) _queueWrites(
    String area,
    _OnDisk disk,
    CloudQueue next,
  ) {
    final writes = <_Write>[];
    final kept = <int>{};
    final putEntries = <QueueEntry>[];
    for (final entry in next.entries) {
      kept.add(entry.place);
      final before = disk.entries[entry.place];
      if (identical(before, entry) || before == entry) continue;
      if (entry is UnreadableEntry) continue;
      writes.add(_PutEntry(area, entry));
      putEntries.add(entry);
    }
    final dropped = [
      for (final place in disk.entries.keys)
        if (!kept.contains(place)) place,
    ];
    for (final place in dropped) {
      writes.add(_DeleteName(area, PendingName(place).name));
    }
    final putAttempts = <AttemptFact>[];
    for (final attempt in next.attempts.values) {
      if (disk.attempts[attempt.number] != attempt) {
        writes.add(_PutAttempt(area, attempt));
        putAttempts.add(attempt);
      }
    }
    final candidates = [
      for (final number in disk.attempts.keys)
        if (!next.attempts.containsKey(number)) number,
    ];
    final droppedAttempts = <int>[];
    if (candidates.isNotEmpty) {
      final highest = _highest(disk.attempts.keys);
      final unansweredOnDisk = {
        for (final entry in disk.entries.values)
          if (entry case PendingOp(answer: NotAnswered())) entry.id,
      };
      for (final number in candidates) {
        if (number == highest) continue;
        if (disk.attempts[number]!.opIds.any(unansweredOnDisk.contains)) {
          continue;
        }
        writes.add(_DeleteName(area, AttemptName(number).name));
        droppedAttempts.add(number);
      }
    }
    final facts = next.strategy;
    final factsChanged = facts != disk.facts;
    if (factsChanged) writes.add(_PutFacts(area, facts));
    final counters = Counters(
      nextAttempt: next.nextAttempt,
      nextRead: next.nextRead,
    );
    final countersChanged = counters != disk.counters;
    if (countersChanged) writes.add(_PutCounters(area, counters));
    return (
      writes,
      () {
        for (final entry in putEntries) {
          disk.entries[entry.place] = entry;
        }
        dropped.forEach(disk.entries.remove);
        for (final attempt in putAttempts) {
          disk.attempts[attempt.number] = attempt;
        }
        droppedAttempts.forEach(disk.attempts.remove);
        if (factsChanged) disk.facts = facts;
        if (countersChanged) disk.counters = counters;
      },
    );
  }

  (List<_Write>, void Function()) _evidenceWrites(
    String area,
    _OnDisk disk,
    BaseFacts base,
    Iterable<String?> pages,
  ) {
    final writes = <_Write>[];
    final groups = _groupsTouched(base, pages);
    for (final MapEntry(key: page, value: group) in groups.entries) {
      if (disk.groups[page] != group) writes.add(_PutGroup(area, page, group));
    }
    return (
      writes,
      () {
        disk.groups.addAll(groups);
        disk.base = base;
      },
    );
  }

  Future<Stored<StrategySummary>> _cloudSummaryAll(
    LoadedStrategy strategy,
    CloudQueue queue,
  ) async {
    final Visible visible;
    switch (await _visibleFor(strategy, queue, const AllPages())) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(:final value):
        visible = value;
    }
    final rows = visible.rows;
    return Done(
      StrategySummary.of(
        strategy: rows.strategy,
        pages: rows.pages,
        settings: rows.settings,
        tallies: {
          for (final page in rows.pages)
            page.publicId: _tallyOn(rows, page.publicId),
        },
        elsewhere: strategy.elsewhere,
        sync: _syncOf(queue, _clock()),
      ),
    );
  }

  Future<Stored<StrategySummary>> _cloudSummaryOver(
    LoadedStrategy strategy,
    CloudQueue queue,
    StrategySummary previous,
    Set<String> pages,
  ) async {
    final Visible visible;
    switch (await _visibleFor(strategy, queue, SomePages(pages))) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(:final value):
        visible = value;
    }
    final rows = visible.rows;
    return Done(
      StrategySummary.of(
        strategy: rows.strategy,
        pages: rows.pages,
        settings: rows.settings,
        tallies: {
          ...previous.tallies,
          for (final page in pages) page: _tallyOn(rows, page),
        },
        elsewhere: strategy.elsewhere,
        sync: _syncOf(queue, _clock()),
      ),
    );
  }

  Future<CommitResult> _commitCloud(_CloudReady cloud, StrategyOp op) async {
    final strategy = cloud.strategy;
    final queue = cloud.queue;
    final ownPages = {
      ...pagesNeeded(op),
      for (final digest in switch (op) {
        ElementAddOp(:final elementPublicId) ||
        ElementPatchOp(:final elementPublicId) ||
        ElementDeleteOp(:final elementPublicId) ||
        ElementReorderOp(
          :final elementPublicId,
        ) => strategy.pagesOfElement(elementPublicId),
        LineupGroupAddOp(:final lineupPublicId) ||
        LineupGroupPatchOp(:final lineupPublicId) ||
        LineupGroupDeleteOp(:final lineupPublicId) ||
        LineupGroupReorderOp(
          :final lineupPublicId,
        ) => strategy.pagesOfLineupGroup(lineupPublicId),
        _ => const <String>[],
      })
        ?strategy.pageIdOf(digest),
      for (final entry in queue.current.entries)
        if (entry is PendingOp && targetOf(entry.op) == targetOf(op))
          ...pagesOf(entry),
    };
    final Visible visible;
    switch (await _visibleFor(strategy, queue.current, SomePages(ownPages))) {
      case StorageFailed(:final failure):
        return NotSaved(failure);
      case Done(:final value):
        visible = value;
    }
    final rows = visible.rows;
    final OpApplied applied;
    switch (applyOp(rows, op)) {
      case OpUnchanged():
        return const NothingToSave();
      case OpRefused(:final refusal):
        return Refused(OpRefusal(refusal));
      case final OpApplied result:
        applied = result;
    }
    final authored = authoredFor(rows, op);
    final rowPage = switch (op) {
      ElementPatchOp(:final elementPublicId) =>
        rows.element(elementPublicId)?.pagePublicId,
      LineupGroupPatchOp(:final lineupPublicId) =>
        rows.lineupGroup(lineupPublicId)?.pagePublicId,
      _ => null,
    };
    EditMaking made(StrategyOp op) =>
        editOf(op, authored: authored, rowPage: rowPage);
    final Edit edit;
    switch ((op, made(op))) {
      case (final PageDeleteOp delete, _):
        edit = PageDeleteEdit(
          delete,
          seenPageIn(rows, delete.pagePublicId),
          authored,
        );
      case (_, EditMade(edit: final found)):
        edit = found;
      case (_, NeedsFieldBase()):
        switch (made(withFieldBase(rows, op))) {
          case EditMade(edit: final found):
            edit = found;
          case NeedsFieldBase() || NeedsRowPage() || NeedsPageDeleteEdit():
            return Refused(OpRefusal(const Rejected(RejectionReason.notFound)));
        }
      case (_, NeedsRowPage() || NeedsPageDeleteEdit()):
        return Refused(OpRefusal(const Rejected(RejectionReason.notFound)));
    }
    final CloudQueue next;
    switch (transition(queue.current, UserEdited(edit), now: _clock())) {
      case NotApplicable(:final why):
        return Refused(QueueRefusal(why));
      case Stepped(queue: final stepped):
        next = stepped;
    }
    final summary = _summaries[strategy.digest];
    if (summary == null) return Refused(NoSuchStrategy(cloud.header.publicId));
    final after = rows.withRows(applied.rows);
    final summaryAfter = summary
        .after(after.strategy, after.pages, after.settings, applied.writes)
        .withSync(_syncOf(next, _clock()));
    final (writes, written) = _queueWrites(strategy.area, queue.disk, next);
    final result = await _commit<Committed, CommitRefusal>(
      [...writes, _PutSummary(strategy.digest, summaryAfter)],
      () {
        written();
        queue.current = next;
        _summaries[strategy.digest] = summaryAfter;
        _unsaved.remove(strategy.digest);
        return Committed(
          change: StrategyEdited(
            strategyPublicId: cloud.header.publicId,
            opId: op.opId,
            writes: applied.writes,
            removed: const [],
            summary: summaryAfter,
          ),
          undo: applied.undo,
        );
      },
    );
    if (result case Saved(:final value)) _emit(value.change);
    return result;
  }

  List<_Write> _forgetPage(LoadedStrategy strategy, String pageDigest) {
    final area = strategy.area;
    final page = strategy.loadedPage(pageDigest);
    return [
      if (strategy.hasPageRow(pageDigest))
        _DeleteName(area, PageName(pageDigest).name),
      if (strategy.settingsOf(strategy.pageIdOf(pageDigest) ?? '') != null)
        _DeleteName(area, SettingsName(pageDigest).name),
      if (page != null) ...[
        for (final row in page.elements.values)
          _DeleteName(area, nameOf(row).name),
        for (final row in page.lineupGroups.values)
          _DeleteName(area, nameOf(row).name),
        for (final row in page.unplaced.values) _DeleteName(area, row.ref.name),
        for (final row in page.unknownKinds) _DeleteName(area, row.key),
      ],
    ];
  }

  Future<Stored<(List<_Write>, void Function())>> _baseRowWrites(
    LoadedStrategy strategy,
    ArrivedBase base,
  ) async {
    final area = strategy.area;
    switch (base) {
      case HeaderRead(strategy: final header, :final pages, :final settings):
        final kept = {for (final page in pages) digestOf(page.publicId)};
        final gone = [
          for (final page in strategy.pageDigests)
            if (!kept.contains(page)) page,
        ];
        if (await _loadPages(strategy, gone) case StorageFailed(
          :final failure,
        )) {
          return StorageFailed(failure);
        }
        final headerStored = switch (strategy.header) {
          HeaderPlaced(:final row) => row == header,
          HeaderUnplaced() || HeaderAbsent() => false,
        };
        final rows = <Row>[
          if (!headerStored) header,
          for (final page in pages)
            if (strategy.page(page.publicId) != page) page,
          for (final row in settings)
            if (strategy.settingsOf(row.pagePublicId) != row) row,
        ];
        return Done((
          [
            for (final row in rows) _PutRow(area, row),
            for (final page in gone) ..._forgetPage(strategy, page),
          ],
          () {
            gone.forEach(strategy.forgetPage);
            rows.forEach(strategy.keepRow);
          },
        ));
      case PageRead(:final page, :final elements, :final lineupGroups):
        final digest = digestOf(page.publicId);
        if (!strategy.hasPageRow(digest)) {
          return Done((const <_Write>[], () {}));
        }
        final elsewhere = {
          for (final row in elements) ...strategy.pagesOfElement(row.publicId),
          for (final row in lineupGroups)
            ...strategy.pagesOfLineupGroup(row.publicId),
        };
        if (await _loadPages(strategy, {digest, ...elsewhere})
            case StorageFailed(:final failure)) {
          return StorageFailed(failure);
        }
        final loaded = strategy.loadedPage(digest)!;
        final read = <Row>[...elements, ...lineupGroups];
        final readKeys = {for (final row in read) row.key};
        final moved = <Row>[
          for (final row in read)
            ...switch (row) {
              ElementRow(:final publicId) => [
                for (final other in strategy.pagesOfElement(publicId))
                  if (other != digest)
                    ?strategy.loadedPage(other)?.elements[digestOf(publicId)],
              ],
              LineupGroupRow(:final publicId) => [
                for (final other in strategy.pagesOfLineupGroup(publicId))
                  if (other != digest)
                    ?strategy.loadedPage(other)?.lineupGroups[digestOf(
                      publicId,
                    )],
              ],
              _ => const <Row>[],
            },
        ];
        final stale = <Row>[
          for (final row in [
            ...loaded.elements.values,
            ...loaded.lineupGroups.values,
          ])
            if (!readKeys.contains(row.key)) row,
        ];
        bool stored(Row row) => switch (strategy.heldUnder(nameOf(row))) {
          HeldRow(row: final held) => held == row,
          HeldNothing() || HeldUnplaced() => false,
        };
        final changed = [
          for (final row in read)
            if (!stored(row)) row,
        ];
        return Done((
          [
            for (final row in [...moved, ...stale])
              _DeleteName(area, nameOf(row).name),
            for (final row in changed) _PutRow(area, row),
          ],
          () {
            [...moved, ...stale].forEach(strategy.forgetRow);
            changed.forEach(strategy.keepRow);
          },
        ));
      case PageGone(:final pagePublicId):
        final digest = digestOf(pagePublicId);
        if (!strategy.pageDigests.contains(digest)) {
          return Done((const <_Write>[], () {}));
        }
        if (await _loadPages(strategy, [digest]) case StorageFailed(
          :final failure,
        )) {
          return StorageFailed(failure);
        }
        return Done((
          _forgetPage(strategy, digest),
          () => strategy.forgetPage(digest),
        ));
      case StrategyGone():
        return Done((const <_Write>[], () {}));
    }
  }

  Future<Saving<void, CommitRefusal>> _flushQueue(
    _CloudReady cloud,
    CloudQueue next,
    Set<String> pagesChanged, {
    required bool headerChanged,
    required Set<String?> evidence,
  }) async {
    final strategy = cloud.strategy;
    final previous = _summaries[strategy.digest];
    final StrategySummary summary;
    if (previous == null) {
      switch (await _cloudSummaryAll(strategy, next)) {
        case StorageFailed(:final failure):
          return NotSaved(failure);
        case Done(:final value):
          summary = value;
      }
    } else if (pagesChanged.isEmpty && !headerChanged) {
      summary = previous.withSync(_syncOf(next, _clock()));
    } else {
      switch (await _cloudSummaryOver(strategy, next, previous, pagesChanged)) {
        case StorageFailed(:final failure):
          return NotSaved(failure);
        case Done(:final value):
          summary = value;
      }
    }
    final (queueWrites, queueWritten) = _queueWrites(
      strategy.area,
      cloud.queue.disk,
      next,
    );
    final (evidenceWrites, evidenceWritten) = _evidenceWrites(
      strategy.area,
      cloud.queue.disk,
      next.base,
      evidence,
    );
    if (evidenceWrites.isNotEmpty) {
      switch (await _commit<void, CommitRefusal>(
        evidenceWrites,
        evidenceWritten,
      )) {
        case Saved() || NothingToSave():
          break;
        case final failed:
          return failed;
      }
    }
    final writes = queueWrites;
    final written = queueWritten;
    final summaryChanged =
        summary != previous || _unsaved.contains(strategy.digest);
    if (writes.isEmpty && !summaryChanged) {
      cloud.queue.current = next;
      return const NothingToSave();
    }
    return _commit<void, CommitRefusal>(
      [...writes, if (summaryChanged) _PutSummary(strategy.digest, summary)],
      () {
        written();
        cloud.queue.current = next;
        _summaries[strategy.digest] = summary;
        _unsaved.remove(strategy.digest);
      },
    );
  }

  Future<RecordResult> _recordCloud(
    String strategyPublicId,
    List<QueueEvent> events,
  ) async {
    final _CloudReady cloud;
    switch (await _openCloud(strategyPublicId)) {
      case _CloudRefused(:final refusal):
        return Refused(refusal);
      case _CloudUnread(:final failure):
        return NotSaved(failure);
      case final _CloudReady ready:
        cloud = ready;
    }
    final strategy = cloud.strategy;
    final outcomes = <ReportOutcome>[];
    var queue = cloud.queue.current;
    final pagesChanged = <String>{};
    final evidence = <String?>{};
    var headerChanged = false;
    RecordResult? failure(Saving<void, CommitRefusal> result) =>
        switch (result) {
          Saved() || NothingToSave() => null,
          NotSaved(:final failure) => NotSaved(failure),
          SaveInDoubt(:final failure) => SaveInDoubt(failure),
          Refused(:final reason) => Refused(reason),
        };
    Future<RecordResult?> flush() async {
      final result = await _flushQueue(
        cloud,
        queue,
        pagesChanged,
        headerChanged: headerChanged,
        evidence: evidence,
      );
      pagesChanged.clear();
      evidence.clear();
      headerChanged = false;
      return failure(result);
    }

    for (final event in events) {
      switch (event) {
        case UserEdited():
          outcomes.add(const EditsGoThroughCommit());
        case BaseArrived(:final base):
          final Stepped step;
          switch (transition(queue, event, now: _clock())) {
            case NotApplicable(:final why):
              outcomes.add(ReportNotApplicable(why));
              continue;
            case final Stepped stepped:
              step = stepped;
          }
          if (await flush() case final stop?) return stop;
          final List<_Write> rowWrites;
          final void Function() rowsTaken;
          switch (await _baseRowWrites(strategy, base)) {
            case StorageFailed(:final failure):
              return NotSaved(failure);
            case Done(value: (final writes, final taken)):
              rowWrites = writes;
              rowsTaken = taken;
          }
          if (rowWrites.isNotEmpty) {
            final landed = await _commit<void, CommitRefusal>(
              rowWrites,
              rowsTaken,
            );
            if (failure(landed) case final stop?) return stop;
          }
          evidence.addAll({
            null,
            switch (base) {
              PageRead(:final page) => page.publicId,
              PageGone(:final pagePublicId) => pagePublicId,
              HeaderRead() || StrategyGone() => null,
            },
          });
          queue = step.queue;
          switch (base) {
            case HeaderRead():
              headerChanged = true;
            case PageRead(:final page):
              pagesChanged.add(page.publicId);
            case PageGone():
              headerChanged = true;
            case StrategyGone():
              break;
          }
          outcomes.add(ReportApplied(step.effects));
        case _:
          switch (transition(queue, event, now: _clock())) {
            case NotApplicable(:final why):
              outcomes.add(ReportNotApplicable(why));
            case Stepped(queue: final next, :final effects):
              queue = next;
              outcomes.add(ReportApplied(effects));
          }
      }
    }
    if (await flush() case final stop?) return stop;
    final summary = _summaries[strategy.digest]!;
    _emit(
      StrategyRefreshed(strategyPublicId: strategyPublicId, summary: summary),
    );
    return Saved(Recorded(outcomes: outcomes, summary: summary));
  }

  CloudStrategy _syncView(CloudQueue queue) => CloudStrategy(
    queue: queue,
    views: entryViews(queue, _clock()),
    tally: Tally.of(queue, _clock()),
  );

  Future<Reading<StrategyContent>> _readCloudStrategy(_CloudReady cloud) async {
    final Visible visible;
    switch (await _visibleFor(
      cloud.strategy,
      cloud.queue.current,
      SomePages(const []),
    )) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        visible = value;
    }
    final rows = visible.rows;
    return Found(
      StrategyContent(
        strategy: rows.strategy,
        pages: LibraryStore._ordered(rows.pages),
        settings: {for (final row in rows.settings) row.pagePublicId: row},
        unplaced: cloud.strategy.allUnplaced,
        foreignNames: cloud.strategy.foreignNames,
        sync: _syncView(cloud.queue.current),
      ),
    );
  }

  Future<Reading<PageContent>> _readCloudPage(
    _CloudReady cloud,
    String pagePublicId,
  ) async {
    final Visible visible;
    switch (await _visibleFor(
      cloud.strategy,
      cloud.queue.current,
      SomePages([pagePublicId]),
    )) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        visible = value;
    }
    final rows = visible.rows;
    final page = rows.page(pagePublicId);
    if (page == null) return const NotFound();
    final loaded = cloud.strategy.loadedPage(digestOf(pagePublicId));
    return Found(
      PageContent(
        page: page,
        settings: switch (rows.settingsOf(pagePublicId)) {
          final row? => SettingsStored(row),
          null => const NoSettingsStored(),
        },
        elements: rows.elementsOn(pagePublicId),
        lineupGroups: rows.lineupGroupsOn(pagePublicId),
        unknownKinds: loaded?.unknownKinds ?? const [],
        unplaced: loaded?.unplaced.values ?? const [],
        foreignNames: loaded?.foreignNames ?? const [],
        sync: _syncView(cloud.queue.current),
      ),
    );
  }

  Future<Saving<StrategySummary, LibraryRefusal>> _addCloud(
    HeaderRead header,
    List<PageRead> pages,
  ) async {
    final ReadableStrategy strategyRow;
    switch (header.strategy) {
      case final ReadableStrategy row:
        strategyRow = row;
      case final UnreadableStrategy row:
        return Refused(UnreadableRowInTheWay(row));
    }
    final id = strategyRow.publicId;
    final digest = digestOf(id);
    final area = strategyArea(id);
    final listed = {for (final page in header.pages) page.publicId};
    for (final read in pages) {
      if (!listed.contains(read.page.publicId)) {
        return Refused(RowOutsideStrategy(read.page.key));
      }
    }
    final List<String> existing;
    switch (await _lease.keys(area, '')) {
      case StorageFailed(:final failure):
        return NotSaved(failure);
      case Done(:final value)
          when value.isNotEmpty &&
              (!value.contains(const CloudName().name) ||
                  value.any(
                    (key) =>
                        key.startsWith(pendingPrefix) ||
                        key.startsWith(attemptPrefix),
                  )):
        return Refused(StrategyAlreadyInStore(id));
      case Done(:final value) when value.isEmpty:
        existing = value;
        switch (await _commit<void, LibraryRefusal>([
          _PutFacts(area, StrategyFacts.fresh),
        ], () {})) {
          case Saved() || NothingToSave():
            break;
          case NotSaved(:final failure):
            return NotSaved(failure);
          case SaveInDoubt(:final failure):
            return SaveInDoubt(failure);
          case Refused(:final reason):
            return Refused(reason);
        }
      case Done(:final value):
        existing = value;
    }
    var queue = CloudQueue.start(build: _build);
    final now = _clock();
    for (final base in <ArrivedBase>[header, ...pages]) {
      final started = transition(queue, const ReadStarted(), now: now);
      queue = (started as Stepped).queue;
      final read = queue.nextRead - 1;
      queue =
          (transition(
                    queue,
                    BaseArrived(base, read: read, startedAt: now),
                    now: now,
                  )
                  as Stepped)
              .queue;
    }
    final rows = StrategyRowSet(
      strategy: strategyRow,
      pages: header.pages,
      settings: header.settings,
      elements: [for (final read in pages) ...read.elements],
      lineupGroups: [for (final read in pages) ...read.lineupGroups],
    );
    final summary = StrategySummary.of(
      strategy: strategyRow,
      pages: rows.pages,
      settings: rows.settings,
      tallies: {
        for (final page in rows.pages)
          page.publicId: _tallyOn(rows, page.publicId),
      },
      elsewhere: PageTally.empty,
      sync: _syncOf(queue, now),
    );
    final written = {
      for (final row in rows.rows) nameOf(row).name,
      const CloudName().name,
    };
    return _commit<StrategySummary, LibraryRefusal>(
      [
        for (final key in existing)
          if (!written.contains(key)) _DeleteName(area, key),
        for (final row in rows.rows) _PutRow(area, row),
        for (final MapEntry(key: page, value: group) in evidenceGroups(
          queue.base,
        ).entries)
          _PutGroup(area, page, group),
        _PutCounters(
          area,
          Counters(nextAttempt: queue.nextAttempt, nextRead: queue.nextRead),
        ),
        _PutSummary(digest, summary),
      ],
      () {
        _summaries[digest] = summary;
        _unsaved.remove(digest);
        _unreadable.remove(digest);
        _strategies.remove(digest);
        _queues.remove(digest);
        return summary;
      },
    );
  }
}
