part of 'store.dart';

final class _OnDisk {
  _OnDisk({
    required this.entries,
    required this.attempts,
    required this.facts,
    required this.groups,
  });

  final Map<int, QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  StrategyFacts facts;
  final Map<String?, String> groups;
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

final class _PutGroup extends _Write {
  const _PutGroup(super.area, this.page, this.text);

  final String? page;
  final String text;
}

final class _PutNumbers extends _Write {
  const _PutNumbers(this.numbers) : super(libraryArea);

  final Counters numbers;
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
    key == const CloudName().name ||
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
    KeptInCloud(Tally(standing: Standing.held, unreadable: rows.length));

DateTime _storedPrecision(DateTime time) => DateTime.fromMillisecondsSinceEpoch(
  time.millisecondsSinceEpoch,
  isUtc: true,
);

QueueEvent _atStoredPrecision(QueueEvent event) => switch (event) {
  BatchClaimed(:final clientId, :final opIds, :final at) => BatchClaimed(
    clientId: clientId,
    opIds: opIds,
    at: _storedPrecision(at),
  ),
  TransportFailed(:final attempt, :final failure, :final at) => TransportFailed(
    attempt,
    failure,
    at: _storedPrecision(at),
  ),
  _ => event,
};

Counters _higher(Counters a, Counters b) => Counters(
  nextAttempt: a.nextAttempt > b.nextAttempt ? a.nextAttempt : b.nextAttempt,
  nextRead: a.nextRead > b.nextRead ? a.nextRead : b.nextRead,
);

Counters _numbersOf(CloudQueue queue) =>
    Counters(nextAttempt: queue.nextAttempt, nextRead: queue.nextRead);

typedef _Opened = (LoadedStrategy, ReadableStrategy, CloudQueue?, StrategySync);

typedef _BaseApplied = ({List<_Write> writes, Set<String> pages});

extension _CloudStore on LibraryStore {
  DateTime _cloudNow() => _storedPrecision(_clock());

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
      _PutNumbers(:final numbers) => checked(
        const NumbersName().name,
        countersToJson(numbers),
        (text) => same(countersFromText(text), numbers),
      ),
      _PutGroup(:final page, :final text) =>
        Evidence.readsBack(page, text, _groupName(page))
            ? Done(Put(write.area, _groupName(page), text))
            : wouldNot(_groupName(page), 'does not read back as written'),
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
    final groupsByName = <String, String>{};
    switch (await _lease.entries(area, readPrefix)) {
      case StorageFailed(:final failure):
        return _QueueNotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          groupsByName[key] = value;
        }
    }
    var base = Evidence.none;
    switch (Evidence.fromGroupTexts(groupsByName, _groupName)) {
      case EvidenceRead(:final evidence):
        base = evidence;
      case EvidenceUnreadable(:final name, :final problem):
        cannotRead(name, problem);
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
      if (await _keepHeld(strategy, unreadable) case StorageFailed(
        :final failure,
      )) {
        return _QueueNotRead(failure);
      }
      return _QueueHeld(unreadable);
    }
    final pending = entries.whereType<PendingOp>();
    final mentioned = Counters(
      nextAttempt: [
        _highest(attempts.keys) + 1,
        for (final entry in pending) entry.retriedAfter + 1,
        facts.accessLostAt + 1,
        facts.accessConfirmedAt + 1,
        if (facts.upgradeTold case UpgradeToldTo(:final attempt)) attempt + 1,
      ].fold(1, (most, next) => next > most ? next : most),
      nextRead: [
        base.lastRead + 1,
        for (final attempt in attempts.values) attempt.afterRead + 1,
        for (final entry in pending) ...[
          if (entry.answer
              case AnsweredApplied(:final afterRead) ||
                  AnsweredRefused(:final afterRead))
            afterRead + 1,
          if (entry.memory case Forgotten(:final afterRead)) afterRead + 1,
        ],
      ].fold(1, (most, next) => next > most ? next : most),
    );
    _numbers = _higher(_numbers, mentioned);
    final onDisk = CloudQueue(
      entries: entries,
      attempts: attempts,
      nextAttempt: _numbers.nextAttempt,
      nextRead: _numbers.nextRead,
      base: base,
      strategy: facts,
      session: QueueSession.start(_build, nextRead: _numbers.nextRead),
    );
    final current = switch (transition(
      onDisk,
      AppRestarted(build: _build),
      now: _cloudNow(),
    )) {
      Stepped(:final queue) => queue,
      NotApplicable() => onDisk,
    };
    final loaded = _LoadedQueue(
      _OnDisk(
        entries: {for (final entry in entries) entry.place: entry},
        attempts: {...attempts},
        facts: facts,
        groups: {...base.groupTexts()},
      ),
      current,
    );
    _queues[strategy.digest] = loaded;
    if (_summaries[strategy.digest] case final summary?) {
      _keepInMemory(
        strategy.digest,
        summary.withSync(_syncOf(current, _cloudNow())),
      );
    }
    return _QueueLoaded(loaded);
  }

  Future<Stored<void>> _keepHeld(
    LoadedStrategy strategy,
    List<UnreadableQueueRow> rows,
  ) async {
    final summary = _summaries[strategy.digest];
    if (summary == null) return done;
    final held = summary.withSync(_heldSync(rows));
    if (held == summary && !_unsaved.contains(strategy.digest)) return done;
    return switch (await _commit<void, CommitRefusal>(
      [_PutSummary(strategy.digest, held)],
      () {
        _summaries[strategy.digest] = held;
        _unsaved.remove(strategy.digest);
      },
    )) {
      Saved() || NothingToSave() => done,
      NotSaved(:final failure) ||
      SaveInDoubt(:final failure) => StorageFailed(failure),
      Refused() => done,
    };
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

  ReadableStrategy _baseHeader(LoadedStrategy strategy, ReadableStrategy or) =>
      switch (strategy.header) {
        HeaderPlaced(row: final ReadableStrategy row) => row,
        _ => or,
      };

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

  ({List<_Write> writes, Set<String> pages}) _queueWrites(
    String area,
    _OnDisk disk,
    CloudQueue next,
  ) {
    final writes = <_Write>[];
    final pages = <String>{};
    final kept = <int>{};
    for (final entry in next.entries) {
      kept.add(entry.place);
      final before = disk.entries[entry.place];
      if (identical(before, entry) || before == entry) continue;
      writes.add(_PutEntry(area, entry));
      if (entry case final PendingOp op) pages.addAll(pagesOf(op));
      if (before case final PendingOp op) pages.addAll(pagesOf(op));
    }
    for (final MapEntry(key: place, value: entry) in disk.entries.entries) {
      if (!kept.contains(place)) {
        writes.add(_DeleteName(area, PendingName(place).name));
        if (entry case final PendingOp op) pages.addAll(pagesOf(op));
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
    return (writes: writes, pages: pages);
  }

  List<_Write> _evidenceWrites(
    String area,
    _OnDisk disk,
    Map<String?, String> groups,
  ) => [
    for (final MapEntry(key: page, value: text) in groups.entries)
      if (disk.groups[page] != text) _PutGroup(area, page, text),
    for (final page in disk.groups.keys)
      if (!groups.containsKey(page)) _DeleteName(area, _groupName(page)),
  ];

  void _written(_OnDisk disk, CloudQueue next, Map<String?, String> groups) {
    disk.entries
      ..clear()
      ..addAll({for (final entry in next.entries) entry.place: entry});
    disk.attempts
      ..clear()
      ..addAll(next.attempts);
    disk.facts = next.strategy;
    disk.groups
      ..clear()
      ..addAll(groups);
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
        sync: _syncOf(queue, _cloudNow()),
      ),
    );
  }

  Future<Stored<_BaseApplied>> _applyBase(
    LoadedStrategy strategy,
    List<BaseChange> changes,
  ) async {
    final area = strategy.area;
    final digests = <String>{};
    for (final change in changes) {
      switch (change) {
        case RowPut(row: ElementRow(:final pagePublicId, :final publicId)):
          digests
            ..add(digestOf(pagePublicId))
            ..addAll(strategy.pagesOfElement(publicId));
        case RowPut(row: LineupGroupRow(:final pagePublicId, :final publicId)):
          digests
            ..add(digestOf(pagePublicId))
            ..addAll(strategy.pagesOfLineupGroup(publicId));
        case RowPut():
          break;
        case RowDropped(:final page) || PageDropped(:final page):
          digests.add(digestOf(page));
      }
    }
    if (await _loadPages(strategy, [
          for (final digest in digests)
            if (strategy.hasPageRow(digest)) digest,
        ])
        case StorageFailed(:final failure)) {
      return StorageFailed(failure);
    }
    final before = <String, (StoreName, Row?)>{};
    final gone = <String>{};
    final pages = <String>{};
    Row? held(StoreName name) => switch (strategy.heldUnder(name)) {
      HeldRow(:final row) => row,
      HeldNothing() || HeldUnplaced() => null,
    };
    void remember(StoreName name) =>
        before.putIfAbsent(name.name, () => (name, held(name)));
    void drop(StoreName name) {
      remember(name);
      if (held(name) case final row?) strategy.forgetRow(row);
    }

    StoreName rowName(Target target, String pageDigest) => switch (target) {
      ElementTarget(:final elementPublicId) => ElementName(
        pageDigest,
        digestOf(elementPublicId),
      ),
      LineupTarget(:final lineupPublicId) => LineupName(
        pageDigest,
        digestOf(lineupPublicId),
      ),
      _ => throw StateError('$target is not page content'),
    };
    for (final change in changes) {
      switch (change) {
        case RowPut(:final row):
          final name = nameOf(row);
          remember(name);
          final (target, others) = switch (row) {
            ElementRow(:final publicId) => (
              ElementTarget(publicId) as Target?,
              strategy.pagesOfElement(publicId),
            ),
            LineupGroupRow(:final publicId) => (
              LineupTarget(publicId) as Target?,
              strategy.pagesOfLineupGroup(publicId),
            ),
            _ => (null, const <String>[]),
          };
          if (target != null) {
            for (final digest in [...others]) {
              final other = rowName(target, digest);
              if (other.name != name.name) drop(other);
            }
          }
          if (row case PageRow(:final publicId)) {
            final page = digestOf(publicId);
            if (!strategy.hasPageRow(page) && !strategy.isLoaded(page)) {
              strategy.addLoadedPage(page, LoadedPage());
            }
          }
          strategy.keepRow(row);
          switch (row) {
            case PageRow(:final publicId) ||
                ElementRow(pagePublicId: final publicId) ||
                LineupGroupRow(pagePublicId: final publicId) ||
                PageSettingsRow(pagePublicId: final publicId):
              pages.add(publicId);
            case _:
              break;
          }
        case RowDropped(:final target, :final page):
          drop(rowName(target, digestOf(page)));
          pages.add(page);
        case PageDropped(:final page):
          final digest = digestOf(page);
          pages.add(page);
          remember(PageName(digest));
          remember(SettingsName(digest));
          if (strategy.loadedPage(digest) case final loaded?) {
            for (final row in [
              ...loaded.elements.values,
              ...loaded.lineupGroups.values,
            ]) {
              remember(nameOf(row));
            }
            for (final row in loaded.unplaced.values) {
              gone.add(row.ref.name);
            }
            for (final row in loaded.unknownKinds) {
              gone.add(row.key);
            }
          }
          strategy.forgetPage(digest);
      }
    }
    final writes = <_Write>[
      for (final name in gone) _DeleteName(area, name),
      for (final (name, was) in before.values)
        ...switch ((was, held(name))) {
          (_, final now?) when now != was => [_PutRow(area, now)],
          (_?, null) => [_DeleteName(area, name.name)],
          _ => const <_Write>[],
        },
    ];
    return Done((writes: writes, pages: pages));
  }

  Future<Saving<T, CommitRefusal>> _finishCloud<T>(
    _CloudReady cloud,
    CloudQueue next,
    List<BaseChange> changes,
    Set<String> edited,
    T Function(StrategySummary summary) take,
  ) async {
    final strategy = cloud.strategy;
    final digest = strategy.digest;
    final area = strategy.area;
    final disk = cloud.queue.disk;
    final _BaseApplied base;
    switch (await _applyBase(strategy, changes)) {
      case StorageFailed(:final failure):
        _forgetCloud(digest);
        return NotSaved(failure);
      case Done(:final value):
        base = value;
    }
    final queued = _queueWrites(area, disk, next);
    final groups = next.base.groupTexts();
    final header = _baseHeader(strategy, cloud.header);
    final previous = _summaries[digest];
    final StrategySummary summary;
    if (previous == null) {
      switch (await _cloudSummaryAll(strategy, header, next)) {
        case StorageFailed(:final failure):
          _forgetCloud(digest);
          return NotSaved(failure);
        case Done(:final value):
          summary = value;
      }
    } else {
      final touched = {...base.pages, ...queued.pages, ...edited};
      final StrategyRowSet rows;
      switch (await _visibleFor(strategy, header, next, SomePages(touched))) {
        case StorageFailed(:final failure):
          _forgetCloud(digest);
          return NotSaved(failure);
        case Done(:final value):
          rows = value;
      }
      final missing = [
        for (final page in rows.pages)
          if (!touched.contains(page.publicId) &&
              !previous.tallies.containsKey(page.publicId))
            page.publicId,
      ];
      var all = rows;
      if (missing.isNotEmpty) {
        switch (await _visibleFor(
          strategy,
          header,
          next,
          SomePages({...touched, ...missing}),
        )) {
          case StorageFailed(:final failure):
            _forgetCloud(digest);
            return NotSaved(failure);
          case Done(:final value):
            all = value;
        }
      }
      summary = StrategySummary.of(
        strategy: all.strategy,
        pages: all.pages,
        settings: all.settings,
        tallies: {
          for (final page in all.pages)
            page.publicId:
                touched.contains(page.publicId) ||
                    missing.contains(page.publicId)
                ? _tallyOn(all, page.publicId)
                : previous.tallies[page.publicId]!,
        },
        elsewhere: strategy.elsewhere,
        sync: _syncOf(next, _cloudNow()),
      );
    }
    final numbers = _higher(_numbers, _numbersOf(next));
    final writes = [
      ...base.writes,
      ...queued.writes,
      ..._evidenceWrites(area, disk, groups),
      if (numbers != _numbersStored) _PutNumbers(numbers),
      if (summary != previous || _unsaved.contains(digest))
        _PutSummary(digest, summary),
    ];
    _numbers = numbers;
    if (writes.isEmpty) {
      cloud.queue.current = next;
      return Saved(take(summary));
    }
    final result = await _commit<T, CommitRefusal>(writes, () {
      _written(disk, next, groups);
      cloud.queue.current = next;
      _summaries[digest] = summary;
      _unsaved.remove(digest);
      _numbersStored = numbers;
      return take(summary);
    });
    switch (result) {
      case Saved() || NothingToSave():
        break;
      case NotSaved() || SaveInDoubt() || Refused():
        _forgetCloud(digest);
    }
    return result;
  }

  Set<String> _ownPages(
    LoadedStrategy strategy,
    CloudQueue queue,
    StrategyOp op,
  ) => {
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

  Future<BatchResult> _commitCloud(
    _CloudReady cloud,
    List<StrategyOp> asked,
  ) async {
    final strategy = cloud.strategy;
    final now = _cloudNow();
    var queue = cloud.queue.current.raisedTo(
      nextAttempt: _numbers.nextAttempt,
      nextRead: _numbers.nextRead,
    );
    final pages = {for (final op in asked) ..._ownPages(strategy, queue, op)};
    StrategyRowSet rows;
    switch (await _visibleFor(
      strategy,
      cloud.header,
      queue,
      SomePages(pages),
    )) {
      case StorageFailed(:final failure):
        return NotSaved(failure);
      case Done(:final value):
        rows = value;
    }
    final applied = <(StrategyOp, OpApplied)>[];
    final edited = <String>{...pages};
    for (final op in asked) {
      final OpApplied result;
      switch (applyOp(rows, op)) {
        case OpUnchanged():
          continue;
        case OpRefused(:final refusal):
          return Refused(OpRefusal(refusal));
        case final OpApplied done:
          result = done;
      }
      final List<StrategyOp> ops;
      switch (op) {
        case PageAddOp(copyContentFromPagePublicId: _?):
          switch (expandCopy(rows, op)) {
            case CopyExpanded(ops: final expanded):
              ops = expanded;
            case CopyNotExpanded(result: OpRefused(:final refusal)):
              return Refused(OpRefusal(refusal));
            case CopyNotExpanded():
              continue;
          }
        case _:
          ops = [op];
      }
      var at = rows;
      for (final each in ops) {
        final rowPage = switch (each) {
          ElementPatchOp(:final elementPublicId) =>
            at.element(elementPublicId)?.pagePublicId,
          LineupGroupPatchOp(:final lineupPublicId) =>
            at.lineupGroup(lineupPublicId)?.pagePublicId,
          _ => null,
        };
        final authored = authoredFor(at, each);
        EditMaking made(StrategyOp op) =>
            editOf(op, authored: authored, rowPage: rowPage);
        final Edit edit;
        switch ((each, made(each))) {
          case (final PageDeleteOp delete, _):
            edit = PageDeleteEdit(
              delete,
              seenPageIn(at, delete.pagePublicId),
              authored,
            );
          case (_, EditMade(edit: final found)):
            edit = found;
          case (_, NeedsFieldBase()):
            switch (made(withFieldBase(at, each))) {
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
        switch (transition(queue, UserEdited(edit), now: now)) {
          case NotApplicable(:final why):
            return Refused(QueueRefusal(why));
          case Stepped(queue: final stepped):
            queue = stepped;
        }
        if (applyOp(at, each) case final OpApplied done) {
          at = at.withRows(done.rows);
        }
        edited.addAll(pagesNeeded(each));
      }
      rows = rows.withRows(result.rows);
      applied.add((op, result));
    }
    if (applied.isEmpty) return const NothingToSave();
    final result = await _finishCloud(
      cloud,
      queue,
      const [],
      edited,
      (summary) => List<Committed>.unmodifiable([
        for (final (op, done) in applied)
          Committed(
            change: StrategyEdited(
              strategyPublicId: cloud.header.publicId,
              opId: op.opId,
              writes: done.writes,
              removed: const [],
              summary: summary,
            ),
            undo: done.undo,
          ),
      ]),
    );
    if (result case Saved(:final value)) {
      for (final each in value) {
        _emit(each.change);
      }
    }
    return result;
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
    final now = _cloudNow();
    final outcomes = <ReportOutcome>[];
    final changes = <BaseChange>[];
    var queue = cloud.queue.current.raisedTo(
      nextAttempt: _numbers.nextAttempt,
      nextRead: _numbers.nextRead,
    );
    for (final event in events.map(_atStoredPrecision)) {
      if (event is UserEdited) {
        outcomes.add(const EditsGoThroughCommit());
        continue;
      }
      switch (transition(queue, event, now: now)) {
        case NotApplicable(:final why):
          outcomes.add(ReportNotApplicable(why));
        case Stepped(queue: final next, :final effects):
          queue = next;
          for (final effect in effects) {
            if (effect case BaseRowsChanged(changes: final shown)) {
              changes.addAll(shown);
            }
          }
          outcomes.add(
            ReportApplied([
              for (final effect in effects)
                if (effect is! BaseRowsChanged) effect,
            ]),
          );
      }
    }
    final result = await _finishCloud(
      cloud,
      queue,
      changes,
      const {},
      (summary) => Recorded(outcomes: outcomes, summary: summary),
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
    views: entryViews(queue, _cloudNow()),
    tally: Tally.of(queue, _cloudNow()),
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
        content: switch (queue) {
          final queue?
              when queue.base.proves(PageContentRead(pagePublicId, after: 0))
                      is! Proven &&
                  queue.base.proves(PageIsLive(pagePublicId, after: 0))
                      is Proven =>
            const ContentNotRead(),
          _ => const ContentShown(),
        },
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
    final now = _cloudNow();
    var queue = CloudQueue.start(
      build: _build,
    ).raisedTo(nextAttempt: _numbers.nextAttempt, nextRead: _numbers.nextRead);
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
    final groups = queue.base.groupTexts();
    final numbers = _higher(_numbers, _numbersOf(queue));
    _numbers = numbers;
    return _commit<StrategySummary, LibraryRefusal>(
      [
        _PutFacts(area, StrategyFacts.fresh),
        for (final row in rows.rows) _PutRow(area, row),
        for (final MapEntry(key: page, value: text) in groups.entries)
          _PutGroup(area, page, text),
        _PutNumbers(numbers),
        _PutSummary(digest, summary),
      ],
      () {
        _summaries[digest] = summary;
        _unsaved.remove(digest);
        _unreadable.remove(digest);
        _numbersStored = numbers;
        _forgetCloud(digest);
        _queues[digest] = _LoadedQueue(
          _OnDisk(
            entries: {},
            attempts: {},
            facts: StrategyFacts.fresh,
            groups: {...groups},
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
