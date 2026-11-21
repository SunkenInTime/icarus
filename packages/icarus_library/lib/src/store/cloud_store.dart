part of 'store.dart';

final class _OnDisk {
  _OnDisk({
    required this.entries,
    required this.attempts,
    required this.facts,
    required this.landed,
    required this.groups,
  });

  final Map<int, QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  StrategyFacts facts;
  final Map<(int, int), LandedWork> landed;
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

final class _PutLanded extends _Write {
  const _PutLanded(super.area, this.work);

  final LandedWork work;
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
    key.startsWith(landedPrefix) ||
    key.startsWith(readPrefix);

Map<String?, String> _groupTexts(Shown shown) => {
  for (final MapEntry(:key, :value) in shownToGroups(shown).entries)
    key: switch (encodeJson(value)) {
      Encoded(:final text) => text,
      NotEncoded(:final problem) => throw StateError(problem),
    },
};

String? _groupPage(StoreName name, String text) => switch (name) {
  PageReadName(:final digest) => switch (admit(text)) {
    Admitted(:final json) => switch (plainJson(json)) {
      {'page': final String page} when digestOf(page) == digest => page,
      _ => null,
    },
    NotAdmitted() => null,
  },
  _ => null,
};

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
  nextSession: a.nextSession > b.nextSession ? a.nextSession : b.nextSession,
);

Counters _numbersOf(CloudQueue queue) =>
    Counters(nextAttempt: queue.nextAttempt, nextSession: queue.nextSession);

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
      _PutLanded(:final work) => checked(
        LandedName(work.attempt, work.position).name,
        landedToJson(work),
        (text) => same(landedFromText(work.attempt, work.position, text), work),
      ),
      _PutGroup(:final page, :final text) =>
        shownFromGroups({page: text}) is ShownRead
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
        cannotRead(const CloudName().name, 'the cloud facts row is missing');
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
    final landed = <LandedWork>[];
    switch (await _lease.entries(area, landedPrefix)) {
      case StorageFailed(:final failure):
        return _QueueNotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          switch (readName(storeArea, key)) {
            case LandedName(:final attempt, :final position):
              switch (landedFromText(attempt, position, value)) {
                case CloudRowRead(:final value):
                  landed.add(value);
                case CloudRowUnreadable(:final problem):
                  cannotRead(key, problem);
              }
            case _:
              cannotRead(key, 'a queue row this build does not name');
          }
        }
    }
    landed.sort((a, b) => a.compareTo(b));
    final groups = <String?, String>{};
    switch (await _lease.entries(area, readPrefix)) {
      case StorageFailed(:final failure):
        return _QueueNotRead(failure);
      case Done(:final value):
        for (final (:key, :value) in value) {
          switch (readName(storeArea, key)) {
            case HeaderReadName():
              groups[null] = value;
            case final PageReadName name:
              switch (_groupPage(name, value)) {
                case final page?:
                  groups[page] = value;
                case null:
                  cannotRead(key, 'stored results for another page');
              }
            case _:
              cannotRead(key, 'a queue row this build does not name');
          }
        }
    }
    var shown = Shown.nothing;
    switch (shownFromGroups(groups)) {
      case ShownRead(shown: final read):
        shown = read;
      case ShownUnreadable(:final page, :final problem):
        cannotRead(_groupName(page), problem);
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
        for (final work in landed) work.attempt + 1,
        for (final entry in pending) entry.retriedAfter + 1,
        facts.accessLostAt + 1,
        facts.accessConfirmedAt + 1,
        if (facts.upgradeTold case UpgradeToldTo(:final attempt)) attempt + 1,
      ].fold(1, (most, next) => next > most ? next : most),
      nextSession: [
        2,
        for (final entry in pending) entry.authoredIn + 1,
      ].fold(1, (most, next) => next > most ? next : most),
    );
    _numbers = _higher(_numbers, mentioned);
    final onDisk = CloudQueue(
      entries: entries,
      attempts: attempts,
      landed: landed,
      nextAttempt: _numbers.nextAttempt,
      nextSession: _numbers.nextSession,
      shown: shown,
      strategy: facts,
      session: QueueSession(
        connected: false,
        build: _build,
        number: _numbers.nextSession - 1,
      ),
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
        landed: {
          for (final work in landed) (work.attempt, work.position): work,
        },
        groups: groups,
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
    final landed = {
      for (final work in next.landed) (work.attempt, work.position): work,
    };
    for (final MapEntry(key: at, value: work) in landed.entries) {
      if (disk.landed[at] != work) writes.add(_PutLanded(area, work));
      if (!disk.landed.containsKey(at)) pages.addAll(pagesNeeded(work.op));
    }
    for (final MapEntry(key: at, value: work) in disk.landed.entries) {
      if (!landed.containsKey(at)) {
        writes.add(_DeleteName(area, LandedName(at.$1, at.$2).name));
        pages.addAll(pagesNeeded(work.op));
      }
    }
    return (writes: writes, pages: pages);
  }

  List<_Write> _resultWrites(
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
    disk.landed
      ..clear()
      ..addAll({
        for (final work in next.landed) (work.attempt, work.position): work,
      });
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
    List<ArrivedBase> arrivals,
  ) async {
    final area = strategy.area;
    final digests = <String>{};
    for (final arrival in arrivals) {
      switch (arrival) {
        case HeaderRead(:final pages):
          final listed = {for (final page in pages) digestOf(page.publicId)};
          digests.addAll(
            strategy.pageDigests.where((d) => !listed.contains(d)),
          );
        case PageRead(:final page, :final elements, :final lineupGroups):
          digests.add(digestOf(page.publicId));
          for (final row in elements) {
            digests.addAll(strategy.pagesOfElement(row.publicId));
          }
          for (final row in lineupGroups) {
            digests.addAll(strategy.pagesOfLineupGroup(row.publicId));
          }
        case PageGone(:final pagePublicId):
          digests.add(digestOf(pagePublicId));
        case StrategyGone():
          break;
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

    void dropPage(String page) {
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

    void put(Row row) {
      final name = nameOf(row);
      remember(name);
      if (row case PageRow(:final publicId)) {
        final page = digestOf(publicId);
        if (!strategy.hasPageRow(page) && !strategy.isLoaded(page)) {
          strategy.addLoadedPage(page, LoadedPage());
        }
      }
      final others = switch (row) {
        ElementRow(:final publicId) => [
          for (final digest in [...strategy.pagesOfElement(publicId)])
            ElementName(digest, digestOf(publicId)),
        ],
        LineupGroupRow(:final publicId) => [
          for (final digest in [...strategy.pagesOfLineupGroup(publicId)])
            LineupName(digest, digestOf(publicId)),
        ],
        _ => const <StoreName>[],
      };
      for (final other in others) {
        if (other.name != name.name) drop(other);
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
    }

    int? heldElsewhere(Row row, String page) {
      final (ids, nameAt) = switch (row) {
        ElementRow(:final publicId) => (
          strategy.pagesOfElement(publicId),
          (String digest) =>
              ElementName(digest, digestOf(publicId)) as StoreName,
        ),
        LineupGroupRow(:final publicId) => (
          strategy.pagesOfLineupGroup(publicId),
          (String digest) =>
              LineupName(digest, digestOf(publicId)) as StoreName,
        ),
        _ => (
          const <String>[],
          (String digest) => PageName(digest) as StoreName,
        ),
      };
      int? most;
      for (final digest in [...ids]) {
        if (digest == digestOf(page)) continue;
        if (held(nameAt(digest)) case final other?) {
          final revision = revisionOfRow(other);
          if (revision != null && (most == null || revision > most)) {
            most = revision;
          }
        }
      }
      return most;
    }

    for (final arrival in arrivals) {
      switch (arrival) {
        case HeaderRead(strategy: final header, :final pages, :final settings):
          put(header);
          final listed = {for (final page in pages) page.publicId};
          for (final page in [...strategy.pages]) {
            if (!listed.contains(page.publicId)) dropPage(page.publicId);
          }
          for (final page in pages) {
            put(page);
          }
          final withSettings = {for (final row in settings) row.pagePublicId};
          for (final page in listed) {
            if (!withSettings.contains(page)) {
              drop(SettingsName(digestOf(page)));
            }
          }
          for (final row in settings) {
            put(row);
          }
        case PageRead(:final page, :final elements, :final lineupGroups):
          put(page);
          final found = <String>{};
          for (final row in <Row>[...elements, ...lineupGroups]) {
            found.add(nameOf(row).name);
            final elsewhere = heldElsewhere(row, page.publicId);
            final revision = revisionOfRow(row);
            if (elsewhere != null && revision != null && elsewhere > revision) {
              continue;
            }
            put(row);
          }
          if (strategy.loadedPage(digestOf(page.publicId)) case final loaded?) {
            for (final row in [
              ...loaded.elements.values,
              ...loaded.lineupGroups.values,
            ]) {
              if (!found.contains(nameOf(row).name)) drop(nameOf(row));
            }
          }
          pages.add(page.publicId);
        case PageGone(:final pagePublicId):
          if (strategy.hasPageRow(digestOf(pagePublicId))) {
            dropPage(pagePublicId);
          }
        case StrategyGone():
          break;
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
    List<ArrivedBase> arrivals,
    Set<String> edited,
    T Function(StrategySummary summary) take,
  ) async {
    final strategy = cloud.strategy;
    final digest = strategy.digest;
    final area = strategy.area;
    final disk = cloud.queue.disk;
    final _BaseApplied base;
    switch (await _applyBase(strategy, arrivals)) {
      case StorageFailed(:final failure):
        _forgetCloud(digest);
        return NotSaved(failure);
      case Done(:final value):
        base = value;
    }
    final queued = _queueWrites(area, disk, next);
    final groups = _groupTexts(next.shown);
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
      ..._resultWrites(area, disk, groups),
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
      nextSession: _numbers.nextSession,
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
    final arrivals = <ArrivedBase>[];
    var queue = cloud.queue.current.raisedTo(
      nextAttempt: _numbers.nextAttempt,
      nextSession: _numbers.nextSession,
    );
    for (final event in events.map(_atStoredPrecision)) {
      if (event is UserEdited) {
        outcomes.add(const EditsGoThroughCommit());
        continue;
      }
      final step = transition(queue, event, now: now);
      queue = step.queue;
      switch (step) {
        case NotApplicable(:final why):
          outcomes.add(ReportNotApplicable(why));
        case Stepped(:final effects):
          if (event case BaseArrived(:final base)) arrivals.add(base);
          outcomes.add(ReportApplied(effects));
      }
    }
    final result = await _finishCloud(
      cloud,
      queue,
      arrivals,
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

  Future<void> _keepExpiries(_CloudOpen cloud) async {
    if (cloud is! _CloudReady) return;
    final queue = cloud.queue.current;
    final recorded = recordExpiries(queue, _cloudNow());
    if (identical(recorded, queue)) return;
    await _finishCloud(
      cloud,
      recorded,
      const [],
      const {},
      (summary) => summary,
    );
  }

  Future<Reading<StrategyContent>> _readCloudStrategy(_CloudOpen cloud) async {
    await _keepExpiries(cloud);
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
    await _keepExpiries(cloud);
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
          final queue? when !queue.shown.content.containsKey(pagePublicId) =>
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
    var queue = CloudQueue.start(build: _build).raisedTo(
      nextAttempt: _numbers.nextAttempt,
      nextSession: _numbers.nextSession,
    );
    for (final base in <ArrivedBase>[header, ...pages]) {
      queue = transition(
        queue,
        BaseArrived(base, session: queue.session.number),
        now: now,
      ).queue;
    }
    final read = {for (final read in pages) read.page.publicId: read.page};
    final rows = StrategyRowSet(
      strategy: strategyRow,
      pages: [for (final page in header.pages) read[page.publicId] ?? page],
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
    final groups = _groupTexts(queue.shown);
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
            landed: {},
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
