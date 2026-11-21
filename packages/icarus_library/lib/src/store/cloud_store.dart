part of 'store.dart';

final class _OnDisk {
  _OnDisk({
    required this.entries,
    required this.attempts,
    required this.facts,
    required this.counters,
    required this.groups,
  });

  final Map<int, QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  StrategyFacts facts;
  Counters counters;
  final Map<String?, EvidenceGroup> groups;
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

final class _QueueHeld extends _QueueLoad {
  const _QueueHeld(this.rows);

  final List<UnreadableQueueRow> rows;
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

final class _CloudHeld extends _CloudOpen {
  const _CloudHeld(this.strategy, this.header, this.rows);

  final LoadedStrategy strategy;
  final ReadableStrategy header;
  final List<UnreadableQueueRow> rows;
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

bool _queueName(String key) =>
    key == const CountersName().name ||
    key.startsWith(pendingPrefix) ||
    key.startsWith(attemptPrefix) ||
    key.startsWith(readPrefix);

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

KeptInCloud _syncOf(CloudQueue queue, DateTime now) =>
    KeptInCloud(Tally.of(queue, now));

KeptInCloud _heldSync(List<UnreadableQueueRow> rows) =>
    KeptInCloud(Tally(standing: Standing.good, unreadable: rows.length));

typedef _Opened = (LoadedStrategy, ReadableStrategy, CloudQueue?, StrategySync);

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
    bool same<T>(CloudRowReading<T> reading, T value) => switch (reading) {
      CloudRowRead(value: final read) => read == value,
      CloudRowUnreadable() => false,
    };
    return switch (write) {
      _PutEntry(:final entry) => checked(
        PendingName(entry.place).name,
        entryToJson(entry),
        (text) => switch (entriesFrom([(entry.place, text)])) {
          EntriesRead(:final entries) => entries.single == entry,
          EntriesUnreadable() => false,
        },
      ),
      _PutAttempt(:final attempt) => checked(
        AttemptName(attempt.number).name,
        attemptToJson(attempt),
        (text) => same(attemptFromText(attempt.number, text), attempt),
      ),
      _PutFacts(:final facts) => checked(
        const CloudName().name,
        factsToJson(facts),
        (text) => same(factsFromText(text), facts),
      ),
      _PutCounters(:final counters) => checked(
        const CountersName().name,
        countersToJson(counters),
        (text) => same(countersFromText(text), counters),
      ),
      _PutGroup(:final page, :final group) => checked(
        _groupName(page),
        groupToJson(page, group),
        (text) =>
            same(groupFromText(text, header: page == null), (page, group)),
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
    final unreadable = <UnreadableQueueRow>[];
    void cannotRead(String name, String problem) =>
        unreadable.add(UnreadableQueueRow(strategy.refOf(name), problem));
    var facts = StrategyFacts.fresh;
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
            cannotRead(const CloudName().name, problem);
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
            cannotRead(const CountersName().name, problem);
        }
    }
    final stored = <(int, String)>[];
    switch (await _lease.entries(area, pendingPrefix)) {
      case StorageFailed(:final failure):
        return _QueueNotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          switch (readName(storeArea, key)) {
            case PendingName(:final place):
              stored.add((place, value));
            case _:
              cannotRead(key, 'a queue row this build does not name');
          }
        }
    }
    final attempts = <int, AttemptFact>{};
    switch (await _lease.entries(area, attemptPrefix)) {
      case StorageFailed(:final failure):
        return _QueueNotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          switch (readName(storeArea, key)) {
            case AttemptName(:final number):
              switch (attemptFromText(number, value)) {
                case CloudRowRead(:final value):
                  attempts[number] = value;
                case CloudRowUnreadable(:final problem):
                  cannotRead(key, problem);
              }
            case _:
              cannotRead(key, 'a queue row this build does not name');
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
          switch (groupFromText(value, header: name is HeaderReadName)) {
            case CloudRowRead(value: (final page, final group))
                when (name is HeaderReadName && page == null) ||
                    (name is PageReadName &&
                        page != null &&
                        namesId(name.digest, page)):
              groups[page] = group;
            case CloudRowRead():
              cannotRead(key, 'evidence kept under another name');
            case CloudRowUnreadable(:final problem):
              cannotRead(key, problem);
          }
        }
    }
    final List<QueueEntry> entries;
    switch (entriesFrom(stored)) {
      case EntriesRead(entries: final read):
        entries = read;
      case EntriesUnreadable(:final place, :final problem):
        cannotRead(PendingName(place).name, problem);
        entries = const [];
    }
    if (unreadable.isNotEmpty) {
      _held[strategy.digest] = unreadable;
      if (_summaries[strategy.digest] case final summary?) {
        _keepInMemory(strategy.digest, summary.withSync(_heldSync(unreadable)));
      }
      return _QueueHeld(unreadable);
    }
    _held.remove(strategy.digest);
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
      for (final attempt in attempts.values) attempt.afterRead + 1,
      for (final entry in pending) ...[
        if (entry.answer
            case AnsweredApplied(:final afterRead) ||
                AnsweredRefused(:final afterRead))
          afterRead + 1,
        if (entry.memory case Forgotten(:final afterRead)) afterRead + 1,
      ],
    ].fold(1, (most, next) => next > most ? next : most);
    final onDisk = CloudQueue(
      entries: entries,
      attempts: attempts,
      nextAttempt: nextAttempt,
      nextRead: nextRead,
      base: base,
      strategy: facts,
      session: QueueSession.start(_build, nextRead: nextRead),
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
        attempts: {...attempts},
        facts: facts,
        counters: counters,
        groups: groups,
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
      _QueueHeld(:final rows) => _CloudHeld(strategy, header, rows),
      _QueueNotRead(:final failure) => _CloudUnread(failure),
      _QueueRefused(:final refusal) => _CloudRefused(refusal),
    };
  }

  void _forgetCloud(String digest) {
    _strategies.remove(digest);
    _queues.remove(digest);
    _held.remove(digest);
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

  Future<Stored<StrategyRowSet>> _visibleFor(
    LoadedStrategy strategy,
    ReadableStrategy header,
    CloudQueue? queue,
    Pages pages,
  ) async {
    final wanted = switch ((queue, pages)) {
      (_, AllPages()) => strategy.pageDigests,
      (null, SomePages(:final pages)) => {
        for (final page in pages) digestOf(page),
      },
      (final queue?, SomePages()) => {
        for (final page in pagesToLoad(queue, pages)) digestOf(page),
      },
    };
    final digests = [
      for (final digest in wanted)
        if (strategy.hasPageRow(digest)) digest,
    ];
    if (await _loadPages(strategy, digests) case StorageFailed(
      :final failure,
    )) {
      return StorageFailed(failure);
    }
    final base = _baseRows(strategy, header);
    return Done(queue == null ? base : visibleOver(base, queue, pages));
  }

  List<_Write> _queueWrites(String area, _OnDisk disk, CloudQueue next) {
    final writes = <_Write>[];
    final kept = <int>{};
    for (final entry in next.entries) {
      kept.add(entry.place);
      final before = disk.entries[entry.place];
      if (identical(before, entry) || before == entry) continue;
      writes.add(_PutEntry(area, entry));
    }
    for (final place in disk.entries.keys) {
      if (!kept.contains(place)) {
        writes.add(_DeleteName(area, PendingName(place).name));
      }
    }
    for (final attempt in next.attempts.values) {
      if (disk.attempts[attempt.number] != attempt) {
        writes.add(_PutAttempt(area, attempt));
      }
    }
    for (final number in disk.attempts.keys) {
      if (!next.attempts.containsKey(number)) {
        writes.add(_DeleteName(area, AttemptName(number).name));
      }
    }
    if (next.strategy != disk.facts) writes.add(_PutFacts(area, next.strategy));
    final counters = Counters(
      nextAttempt: next.nextAttempt,
      nextRead: next.nextRead,
    );
    if (counters != disk.counters) writes.add(_PutCounters(area, counters));
    return writes;
  }

  List<_Write> _evidenceWrites(String area, _OnDisk disk, BaseFacts base) {
    final groups = evidenceGroups(base);
    return [
      for (final MapEntry(key: page, value: group) in groups.entries)
        if (disk.groups[page] != group) _PutGroup(area, page, group),
      for (final page in disk.groups.keys)
        if (!groups.containsKey(page)) _DeleteName(area, _groupName(page)),
    ];
  }

  void _written(_OnDisk disk, CloudQueue next, {required bool base}) {
    disk.entries
      ..clear()
      ..addAll({for (final entry in next.entries) entry.place: entry});
    disk.attempts
      ..clear()
      ..addAll(next.attempts);
    disk.facts = next.strategy;
    disk.counters = Counters(
      nextAttempt: next.nextAttempt,
      nextRead: next.nextRead,
    );
    if (base) {
      disk.groups
        ..clear()
        ..addAll(evidenceGroups(next.base));
    }
  }

  Future<Stored<StrategySummary>> _cloudSummaryAll(
    LoadedStrategy strategy,
    ReadableStrategy header,
    CloudQueue queue,
  ) async {
    final StrategyRowSet rows;
    switch (await _visibleFor(strategy, header, queue, const AllPages())) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(:final value):
        rows = value;
    }
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

  Future<Stored<StrategySummary>> _summaryAfter(
    _CloudReady cloud,
    CloudQueue next,
    Set<String> pages, {
    required bool header,
  }) async {
    final strategy = cloud.strategy;
    final previous = _summaries[strategy.digest];
    final ReadableStrategy base;
    switch (strategy.header) {
      case HeaderPlaced(row: final ReadableStrategy row):
        base = row;
      case _:
        base = cloud.header;
    }
    if (previous == null) return _cloudSummaryAll(strategy, base, next);
    if (pages.isEmpty && !header) {
      return Done(previous.withSync(_syncOf(next, _clock())));
    }
    final StrategyRowSet rows;
    switch (await _visibleFor(strategy, base, next, SomePages(pages))) {
      case StorageFailed(:final failure):
        return StorageFailed(failure);
      case Done(:final value):
        rows = value;
    }
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
        sync: _syncOf(next, _clock()),
      ),
    );
  }

  Future<Saving<T, CommitRefusal>> _commitCloudChanges<T>(
    _CloudReady cloud,
    CloudQueue next,
    List<_Write> rowWrites,
    StrategySummary summary,
    T Function() take,
  ) async {
    final strategy = cloud.strategy;
    final disk = cloud.queue.disk;
    final baseChanged = !identical(next.base, cloud.queue.current.base);
    final writes = [
      ...rowWrites,
      ..._queueWrites(strategy.area, disk, next),
      if (baseChanged) ..._evidenceWrites(strategy.area, disk, next.base),
      if (summary != _summaries[strategy.digest] ||
          _unsaved.contains(strategy.digest))
        _PutSummary(strategy.digest, summary),
    ];
    if (writes.isEmpty) {
      cloud.queue.current = next;
      return Saved(take());
    }
    final result = await _commit<T, CommitRefusal>(writes, () {
      _written(disk, next, base: baseChanged);
      cloud.queue.current = next;
      _summaries[strategy.digest] = summary;
      _unsaved.remove(strategy.digest);
      return take();
    });
    switch (result) {
      case Saved() || NothingToSave():
        break;
      case NotSaved() || SaveInDoubt() || Refused():
        _forgetCloud(strategy.digest);
    }
    return result;
  }

  Future<CommitResult> _commitCloud(_CloudReady cloud, StrategyOp op) async {
    final strategy = cloud.strategy;
    var queue = cloud.queue.current;
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
      for (final entry in queue.entries)
        if (entry is PendingOp && targetOf(entry.op) == targetOf(op))
          ...pagesOf(entry),
    };
    final StrategyRowSet before;
    switch (await _visibleFor(
      strategy,
      cloud.header,
      queue,
      SomePages(ownPages),
    )) {
      case StorageFailed(:final failure):
        return NotSaved(failure);
      case Done(:final value):
        before = value;
    }
    final OpApplied applied;
    switch (applyOp(before, op)) {
      case OpUnchanged():
        return const NothingToSave();
      case OpRefused(:final refusal):
        return Refused(OpRefusal(refusal));
      case final OpApplied result:
        applied = result;
    }
    final List<StrategyOp> ops;
    switch (op) {
      case PageAddOp(copyContentFromPagePublicId: _?):
        switch (expandCopy(before, op)) {
          case CopyExpanded(ops: final expanded):
            ops = expanded;
          case CopyNotExpanded(result: OpRefused(:final refusal)):
            return Refused(OpRefusal(refusal));
          case CopyNotExpanded():
            return const NothingToSave();
        }
      case _:
        ops = [op];
    }
    var rows = before;
    for (final each in ops) {
      final rowPage = switch (each) {
        ElementPatchOp(:final elementPublicId) =>
          rows.element(elementPublicId)?.pagePublicId,
        LineupGroupPatchOp(:final lineupPublicId) =>
          rows.lineupGroup(lineupPublicId)?.pagePublicId,
        _ => null,
      };
      final authored = authoredFor(rows, each);
      EditMaking made(StrategyOp op) =>
          editOf(op, authored: authored, rowPage: rowPage);
      final Edit edit;
      switch ((each, made(each))) {
        case (final PageDeleteOp delete, _):
          edit = PageDeleteEdit(
            delete,
            seenPageIn(rows, delete.pagePublicId),
            authored,
          );
        case (_, EditMade(edit: final found)):
          edit = found;
        case (_, NeedsFieldBase()):
          switch (made(withFieldBase(rows, each))) {
            case EditMade(edit: final found):
              edit = found;
            case _:
              return Refused(
                OpRefusal(const Rejected(RejectionReason.notFound)),
              );
          }
        case (_, _):
          return Refused(OpRefusal(const Rejected(RejectionReason.notFound)));
      }
      switch (transition(queue, UserEdited(edit), now: _clock())) {
        case NotApplicable(:final why):
          return Refused(QueueRefusal(why));
        case Stepped(queue: final stepped):
          queue = stepped;
      }
      if (applyOp(rows, each) case final OpApplied done) {
        rows = rows.withRows(done.rows);
      }
    }
    final summary = _summaries[strategy.digest];
    if (summary == null) return Refused(NoSuchStrategy(cloud.header.publicId));
    final after = before.withRows(applied.rows);
    final summaryAfter = summary
        .after(after.strategy, after.pages, after.settings, applied.writes)
        .withSync(_syncOf(queue, _clock()));
    final result = await _commitCloudChanges(
      cloud,
      queue,
      const [],
      summaryAfter,
      () => Committed(
        change: StrategyEdited(
          strategyPublicId: cloud.header.publicId,
          opId: op.opId,
          writes: applied.writes,
          removed: const [],
          summary: summaryAfter,
        ),
        undo: applied.undo,
      ),
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

  Future<Stored<List<_Write>>> _acceptedRows(
    LoadedStrategy strategy,
    ArrivedBase arrived,
    int read,
    BaseFacts base,
  ) async {
    final area = strategy.area;
    bool sighted(Target target) => base.sightings[target]?.read == read;
    bool stored(Row row) => switch (strategy.heldUnder(nameOf(row))) {
      HeldRow(row: final held) => held == row,
      HeldNothing() || HeldUnplaced() => false,
    };
    switch (arrived) {
      case HeaderRead(strategy: final header, :final pages, :final settings):
        if (base.header?.read != read) return const Done([]);
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
        final rows = <Row>[
          if (sighted(const StrategyTarget()) &&
              switch (strategy.header) {
                HeaderPlaced(:final row) => row != header,
                HeaderUnplaced() || HeaderAbsent() => true,
              })
            header,
          for (final page in pages)
            if (sighted(PageTarget(page.publicId)) && !stored(page)) page,
          for (final row in settings)
            if (sighted(SettingsTarget(row.pagePublicId)) && !stored(row)) row,
        ];
        final writes = [
          for (final page in gone) ..._forgetPage(strategy, page),
          for (final row in rows) _PutRow(area, row),
        ];
        gone.forEach(strategy.forgetPage);
        rows.forEach(strategy.keepRow);
        return Done(writes);
      case PageRead(:final page, :final elements, :final lineupGroups):
        final digest = digestOf(page.publicId);
        if (base.pageContent[page.publicId]?.read != read) {
          return const Done([]);
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
        final accepted = <Row>[
          for (final row in elements)
            if (sighted(ElementTarget(row.publicId))) row,
          for (final row in lineupGroups)
            if (sighted(LineupTarget(row.publicId))) row,
        ];
        final readKeys = {
          for (final row in elements) row.key,
          for (final row in lineupGroups) row.key,
        };
        final moved = <Row>[
          for (final row in accepted)
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
        final changed = [
          for (final row in accepted)
            if (!stored(row)) row,
        ];
        final writes = [
          for (final row in [...moved, ...stale])
            _DeleteName(area, nameOf(row).name),
          for (final row in changed) _PutRow(area, row),
        ];
        [...moved, ...stale].forEach(strategy.forgetRow);
        changed.forEach(strategy.keepRow);
        return Done(writes);
      case PageGone(:final pagePublicId):
        final digest = digestOf(pagePublicId);
        if (base.notFound[pagePublicId]?.read != read ||
            !strategy.pageDigests.contains(digest)) {
          return const Done([]);
        }
        if (await _loadPages(strategy, [digest]) case StorageFailed(
          :final failure,
        )) {
          return StorageFailed(failure);
        }
        final writes = _forgetPage(strategy, digest);
        strategy.forgetPage(digest);
        return Done(writes);
      case StrategyGone():
        return const Done([]);
    }
  }

  Future<RecordResult> _recordCloud(
    String strategyPublicId,
    List<QueueEvent> events,
  ) async {
    final _CloudReady cloud;
    switch (await _openCloud(strategyPublicId)) {
      case _CloudRefused(:final refusal):
        return Refused(refusal);
      case _CloudHeld(:final rows):
        return Refused(QueueHeld(rows));
      case _CloudUnread(:final failure):
        return NotSaved(failure);
      case final _CloudReady ready:
        cloud = ready;
    }
    final strategy = cloud.strategy;
    final outcomes = <ReportOutcome>[];
    final rowWrites = <_Write>[];
    final pages = <String>{};
    var header = false;
    var queue = cloud.queue.current;
    for (final event in events) {
      switch (event) {
        case UserEdited():
          outcomes.add(const EditsGoThroughCommit());
        case BaseArrived(base: PageRead(:final page))
            when !strategy.hasPageRow(digestOf(page.publicId)):
          outcomes.add(ReportNotApplicable(PageNotStored(page.publicId)));
        case BaseArrived(:final base, :final read):
          switch (transition(queue, event, now: _clock())) {
            case NotApplicable(:final why):
              outcomes.add(ReportNotApplicable(why));
            case Stepped(queue: final next, :final effects):
              switch (await _acceptedRows(strategy, base, read, next.base)) {
                case StorageFailed(:final failure):
                  _forgetCloud(strategy.digest);
                  return NotSaved(failure);
                case Done(:final value):
                  rowWrites.addAll(value);
              }
              queue = next;
              switch (base) {
                case PageRead(:final page):
                  pages.add(page.publicId);
                case HeaderRead() || PageGone():
                  header = true;
                case StrategyGone():
                  break;
              }
              outcomes.add(ReportApplied(effects));
          }
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
    final StrategySummary summary;
    switch (await _summaryAfter(cloud, queue, pages, header: header)) {
      case StorageFailed(:final failure):
        _forgetCloud(strategy.digest);
        return NotSaved(failure);
      case Done(:final value):
        summary = value;
    }
    final result = await _commitCloudChanges(
      cloud,
      queue,
      rowWrites,
      summary,
      () => Recorded(outcomes: outcomes, summary: summary),
    );
    if (result case Saved(:final value)) {
      _emit(
        StrategyRefreshed(
          strategyPublicId: strategyPublicId,
          summary: value.summary,
        ),
      );
    }
    return result;
  }

  CloudStrategy _syncView(CloudQueue queue) => CloudStrategy(
    queue: queue,
    views: entryViews(queue, _clock()),
    tally: Tally.of(queue, _clock()),
  );

  _Opened _opened(_CloudOpen cloud) => switch (cloud) {
    _CloudReady(:final strategy, :final header, :final queue) => (
      strategy,
      header,
      queue.current,
      _syncView(queue.current),
    ),
    _CloudHeld(:final strategy, :final header, :final rows) => (
      strategy,
      header,
      null,
      CloudHeld(rows),
    ),
    _CloudRefused() || _CloudUnread() => throw StateError('not open'),
  };

  Future<Reading<StrategyContent>> _readCloudStrategy(_CloudOpen cloud) async {
    final (strategy, header, queue, sync) = _opened(cloud);
    final StrategyRowSet rows;
    switch (await _visibleFor(strategy, header, queue, SomePages(const []))) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        rows = value;
    }
    return Found(
      StrategyContent(
        strategy: rows.strategy,
        pages: LibraryStore._ordered(rows.pages),
        settings: {for (final row in rows.settings) row.pagePublicId: row},
        unplaced: strategy.allUnplaced,
        foreignNames: strategy.foreignNames,
        sync: sync,
      ),
    );
  }

  Future<Reading<PageContent>> _readCloudPage(
    _CloudOpen cloud,
    String pagePublicId,
  ) async {
    final (strategy, header, queue, sync) = _opened(cloud);
    final StrategyRowSet rows;
    switch (await _visibleFor(
      strategy,
      header,
      queue,
      SomePages([pagePublicId]),
    )) {
      case StorageFailed(:final failure):
        return NotRead(failure);
      case Done(:final value):
        rows = value;
    }
    final page = rows.page(pagePublicId);
    if (page == null) return const NotFound();
    final loaded = strategy.loadedPage(digestOf(pagePublicId));
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
        sync: sync,
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
    switch (await _lease.keys(area, '')) {
      case StorageFailed(:final failure):
        return NotSaved(failure);
      case Done(:final value) when value.isNotEmpty:
        return Refused(StrategyAlreadyInStore(id));
      case Done():
        break;
    }
    var queue = CloudQueue.start(build: _build);
    final now = _clock();
    for (final base in <ArrivedBase>[header, ...pages]) {
      queue = switch (transition(queue, const ReadStarted(), now: now)) {
        Stepped(queue: final next) => next,
        NotApplicable() => queue,
      };
      queue = switch (transition(
        queue,
        BaseArrived(base, read: queue.nextRead - 1),
        now: now,
      )) {
        Stepped(queue: final next) => next,
        NotApplicable() => queue,
      };
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
    return _commit<StrategySummary, LibraryRefusal>(
      [
        _PutFacts(area, StrategyFacts.fresh),
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
        _forgetCloud(digest);
        _queues[digest] = _LoadedQueue(
          _OnDisk(
            entries: {},
            attempts: {},
            facts: StrategyFacts.fresh,
            counters: Counters(
              nextAttempt: queue.nextAttempt,
              nextRead: queue.nextRead,
            ),
            groups: {...evidenceGroups(queue.base)},
          ),
          queue,
        );
        return summary;
      },
    );
  }

  Future<Saving<StrategySummary, CommitRefusal>> _discardHeld(
    String strategyPublicId,
  ) async {
    final digest = digestOf(strategyPublicId);
    final area = strategyArea(strategyPublicId);
    final List<String> keys;
    switch (await _lease.keys(area, '')) {
      case StorageFailed(:final failure):
        return NotSaved(failure);
      case Done(:final value):
        keys = value;
    }
    if (!keys.contains(const CloudName().name)) {
      return Refused(NotACloudStrategy(strategyPublicId));
    }
    final cleared = await _commit<void, CommitRefusal>([
      for (final key in keys)
        if (_queueName(key)) _DeleteName(area, key),
      _PutFacts(area, StrategyFacts.fresh),
    ], () {});
    _forgetCloud(digest);
    _summaries.remove(digest);
    switch (cleared) {
      case Saved() || NothingToSave():
        break;
      case NotSaved(:final failure):
        return NotSaved(failure);
      case SaveInDoubt(:final failure):
        return SaveInDoubt(failure);
      case Refused(:final reason):
        return Refused(reason);
    }
    return switch (await _rebuilt(digest)) {
      _RebuiltSummary(:final summary) =>
        await _commit<StrategySummary, CommitRefusal>(
          [_PutSummary(digest, summary)],
          () {
            _summaries[digest] = summary;
            _unsaved.remove(digest);
            return summary;
          },
        ),
      _RebuildNotRead(:final failure) => NotSaved(failure),
      _HeaderUnreadable(:final row) => Refused(UnreadableRowInTheWay(row)),
      _HeaderMissing(:final ref) => Refused(StrategyNotReadable(ref)),
      _NoStrategyThere() => Refused(NoSuchStrategy(strategyPublicId)),
    };
  }
}
