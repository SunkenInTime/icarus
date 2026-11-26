part of 'store.dart';

final class _OnDisk {
  _OnDisk({
    required this.entries,
    required this.attempts,
    required this.owner,
    required this.facts,
    required this.landed,
    required this.groups,
    required this.shown,
  });

  final Map<int, QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  Account? owner;
  StrategyFacts? facts;
  final Map<(int, int), LandedWork> landed;
  final Map<String?, String> groups;
  final encodedThisRun = <String?, String>{};
  Shown shown;
}

final class _LoadedQueue {
  _LoadedQueue(this.disk, this.current, this.owner);

  final _OnDisk disk;
  CloudQueue current;
  final Account owner;
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
  const _PutFacts(super.area, this.owner, this.facts);

  final Account owner;
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

sealed class _NumbersRow {
  const _NumbersRow();
}

final class _NoNumbersRow extends _NumbersRow {
  const _NoNumbersRow();
}

final class _NumbersRowRead extends _NumbersRow {
  const _NumbersRowRead(this.counters);

  final Counters counters;

  @override
  bool operator ==(Object other) =>
      other is _NumbersRowRead && other.counters == counters;

  @override
  int get hashCode => counters.hashCode;
}

final class _NumbersRowUnreadable extends _NumbersRow {
  const _NumbersRowUnreadable(this.problem);

  final String problem;
}

sealed class _QueueLoad {
  const _QueueLoad();
}

final class _QueueLoaded extends _QueueLoad {
  const _QueueLoaded(this.queue);

  final _LoadedQueue queue;
}

final class _QueueHeld extends _QueueLoad {
  const _QueueHeld(this.rows, this.owner);

  final List<UnreadableQueueRow> rows;
  final CloudOwner owner;
}

final class _QueueNotRead extends _QueueLoad {
  const _QueueNotRead(this.failure);

  final StorageFailure failure;
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
  const _CloudHeld(this.strategy, this.header, this.rows, this.owner);

  final LoadedStrategy strategy;
  final ReadableStrategy header;
  final List<UnreadableQueueRow> rows;
  final CloudOwner owner;
}

final class _CloudRefused extends _CloudOpen {
  const _CloudRefused(this.refusal);

  final CommitRefusal refusal;
}

final class _RowsDisagree implements Exception {
  const _RowsDisagree(this.reason);

  final String reason;
}

final class _CloudUnread extends _CloudOpen {
  const _CloudUnread(this.failure);

  final StorageFailure failure;
}

RowKey? _outOfPlace(String strategyPublicId, ArrivedBase base) =>
    switch (base) {
      HeaderRead(:final strategy, :final pages, :final settings) => [
        if (strategy.publicId != strategyPublicId) strategy.key,
        for (final page in pages)
          if (page.strategyPublicId != strategyPublicId) page.key,
        for (final row in settings)
          if (!pages.any((page) => page.publicId == row.pagePublicId)) row.key,
      ].firstOrNull,
      PageRead(:final page, :final elements, :final lineupGroups) => [
        if (page.strategyPublicId != strategyPublicId) page.key,
        for (final row in elements)
          if (row.pagePublicId != page.publicId) row.key,
        for (final row in lineupGroups)
          if (row.pagePublicId != page.publicId ||
              row.strategyPublicId != strategyPublicId)
            row.key,
      ].firstOrNull,
      PageGone() || StrategyGone() => null,
    };

List<Row> _rowsOf(ArrivedBase base) => switch (base) {
  HeaderRead(:final strategy, :final pages, :final settings) => [
    strategy,
    ...pages,
    ...settings,
  ],
  PageRead(:final page, :final elements, :final lineupGroups) => [
    page,
    ...elements,
    ...lineupGroups,
  ],
  PageGone() || StrategyGone() => const [],
};

CommitRefusal? _unfitResult(String strategyPublicId, List<QueueEvent> events) {
  for (final event in events) {
    if (event case BaseArrived(:final base)) {
      if (_outOfPlace(strategyPublicId, base) case final key?) {
        return ResultOutOfPlace(key);
      }
      for (final row in _rowsOf(base)) {
        if (createdAtOf(row) == null) return ResultWithoutLife(row.key);
      }
    }
  }
  return null;
}

final class _ItemDigests {
  _ItemDigests(this.strategy);

  final LoadedStrategy strategy;
  final _known = <String, String>{};

  void learnPage(String pageDigest) {
    if (strategy.loadedPage(pageDigest) case final loaded?) {
      for (final MapEntry(key: digest, value: row) in loaded.elements.entries) {
        _known[row.publicId] = digest;
      }
      for (final MapEntry(:key, :value) in loaded.lineupGroups.entries) {
        _known[value.publicId] = key;
      }
    }
  }

  String of(String id) => _known[id] ??= digestOf(id);

  StoreName nameOf(Row row, {String? onPage}) => switch (row) {
    ElementRow(:final pagePublicId, :final publicId) => ElementName(
      of(onPage ?? pagePublicId),
      of(publicId),
    ),
    LineupGroupRow(:final pagePublicId, :final publicId) => LineupName(
      of(onPage ?? pagePublicId),
      of(publicId),
    ),
    _ => nameOf(row),
  };
}

bool _comparedEqual(Row now, Row before) {
  storeWork.rowsCompared++;
  return now.runtimeType == before.runtimeType &&
      sameJsonTree(now.toJsonView(), before.toJsonView());
}

String _groupName(String? page) => switch (page) {
  null => const HeaderReadName().name,
  final page => PageReadName(digestOf(page)).name,
};

int _highest(Iterable<int> numbers) =>
    numbers.fold(0, (highest, number) => number > highest ? number : highest);

bool _queueName(String key) => isCloudKey(key);

Set<String> queuePagesOf(PendingOp entry) => pagesOf(entry);

Iterable<String> _rowPages(LoadedStrategy strategy, StrategyOp op) =>
    _cachedPages(strategy, targetOf(op));

Iterable<String> _cachedPages(LoadedStrategy strategy, Target target) => [
  for (final digest in switch (target) {
    ElementTarget(:final elementPublicId) => strategy.pagesOfElement(
      elementPublicId,
    ),
    LineupTarget(:final lineupPublicId) => strategy.pagesOfLineupGroup(
      lineupPublicId,
    ),
    _ => const <String>[],
  })
    ?strategy.pageIdOf(digest),
];

Set<String> _pagesShowingRow(
  LoadedStrategy strategy,
  CloudQueue queue,
  Target target,
) => switch (target) {
  ElementTarget() || LineupTarget() => {
    ..._cachedPages(strategy, target),
    ...pagesShowing(queue, target),
  },
  _ => const {},
};

String _groupText(Map<String, Object?> group) {
  switch (encodeJson(group)) {
    case Encoded(:final text):
      storeWork.resultGroupsEncoded++;
      return text;
    case NotEncoded(:final problem):
      throw StateError(problem);
  }
}

Map<String?, String> _groupTextsSince(
  Shown before,
  Map<String?, String> encodedThisRun,
  Shown shown,
) {
  final texts = <String?, String>{
    for (final MapEntry(:key, :value) in shownToGroupsSince(
      before,
      shown,
      kept: encodedThisRun.containsKey,
    ).entries)
      key: switch (value) {
        null => encodedThisRun[key]!,
        final group => _groupText(group),
      },
  };
  if (shownTakesChecked) {
    final whole = {
      for (final MapEntry(:key, :value) in shownToGroups(shown).entries)
        key: encodeJson(value),
    };
    for (final MapEntry(:key, :value) in whole.entries) {
      if (value case Encoded(:final text) when text == texts[key]) continue;
      throw TakesDiffer.group(key);
    }
    if (texts.length != whole.length) throw TakesDiffer.group(null);
  }
  return texts;
}

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

PageTally _tallyOn(
  LoadedStrategy strategy,
  StrategyRowSet rows,
  String pageId,
) {
  final loaded = strategy.loadedPage(digestOf(pageId));
  return PageTally.count(
    elements: rows.elementsOn(pageId),
    lineupGroups: rows.lineupGroupsOn(pageId),
    damaged: loaded?.unplaced.length ?? 0,
    newer: loaded?.unknownKinds.length ?? 0,
  );
}

KeptInCloud _syncOf(Account owner, CloudQueue queue, DateTime now) =>
    KeptInCloud(OwnedBy(owner), Tally.of(queue, now));

KeptInCloud _heldSync(CloudOwner owner, List<UnreadableQueueRow> rows) =>
    KeptInCloud(owner, Tally(standing: Standing.held, unreadable: rows.length));

DateTime _storedPrecision(DateTime time) => DateTime.fromMillisecondsSinceEpoch(
  time.millisecondsSinceEpoch,
  isUtc: true,
);

QueueEvent _atStoredPrecision(QueueEvent event) => switch (event) {
  BatchClaimed(:final clientId, :final opIds, :final at, :final elapsed) =>
    BatchClaimed(
      clientId: clientId,
      opIds: opIds,
      at: _storedPrecision(at),
      elapsed: elapsed,
    ),
  TransportFailed(:final attempt, :final failure, :final at) => TransportFailed(
    attempt,
    failure,
    at: _storedPrecision(at),
  ),
  BatchRefused(
    :final attempt,
    :final refusal,
    :final at?,
    :final currentLife,
  ) =>
    BatchRefused(
      attempt,
      refusal,
      at: _storedPrecision(at),
      currentLife: currentLife,
    ),
  _ => event,
};

Counters _higher(Counters a, Counters b) => Counters(
  nextAttempt: a.nextAttempt > b.nextAttempt ? a.nextAttempt : b.nextAttempt,
  nextSession: a.nextSession > b.nextSession ? a.nextSession : b.nextSession,
);

Counters _numbersOf(CloudQueue queue) =>
    Counters(nextAttempt: queue.nextAttempt, nextSession: queue.nextSession);

typedef _BaseApplied = ({
  List<_Write> writes,
  Set<String> pages,
  Set<Target> rows,
});

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
      _PutFacts(:final owner, :final facts) => checked(
        const CloudName().name,
        factsToJson(owner, facts),
        (text) => same(factsFromText(text), CloudFacts(owner, facts)),
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
    final listed = _summaries[strategy.digest];
    final unreadable = <UnreadableQueueRow>[];
    void cannotRead(String name, String problem) =>
        unreadable.add(UnreadableQueueRow(strategy.refOf(name), problem));
    var facts = StrategyFacts.fresh;
    CloudOwner owner = const OwnerUnreadable();
    switch (await _lease.read(area, const CloudName().name)) {
      case KeyNotRead(:final failure):
        return _QueueNotRead(failure);
      case KeyMissing():
        cannotRead(const CloudName().name, 'the cloud facts row is missing');
      case KeyHeld(:final value):
        owner = ownerFromText(value);
        switch (factsFromText(value)) {
          case CloudRowRead(:final value):
            facts = value.facts;
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
        shown = read.withTrashedPages(strategy.pages);
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
    if (_numbersHold case final row?) unreadable.add(row);
    if (unreadable.isNotEmpty) {
      if (strategy.header case HeaderPlaced(
        row: final ReadableStrategy header,
      ) when _summaries.containsKey(strategy.digest)) {
        if (await _loadUnchecked(strategy, strategy.pageDigests)
            case StorageFailed(:final failure)) {
          return _QueueNotRead(failure);
        }
        _keepInMemory(
          strategy.digest,
          LibraryStore._summaryOf(
            strategy,
            header,
            const {},
          ).withSync(_heldSync(owner, unreadable)),
        );
      }
      _checked(strategy.digest, listed);
      return _QueueHeld(unreadable, owner);
    }
    final account = switch (owner) {
      OwnedBy(:final account) => account,
      OwnerUnreadable() => throw StateError('an unread owner was not held'),
    };
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
    final kept = _sessions[strategy.digest];
    final onDisk = CloudQueue(
      entries: entries,
      attempts: attempts,
      landed: landed,
      nextAttempt: _numbers.nextAttempt,
      nextSession: _numbers.nextSession,
      shown: switch (kept) {
        (shown: final memory, session: _) when memory.inNewSession() == shown =>
          memory,
        _ => shown,
      },
      strategy: facts,
      session:
          kept?.session ??
          QueueSession(connected: false, build: _build, number: 0, sequence: 0),
    );
    final current = onDisk;
    final loaded = _LoadedQueue(
      _OnDisk(
        entries: {for (final entry in entries) entry.place: entry},
        attempts: {...attempts},
        owner: account,
        facts: facts,
        landed: {
          for (final work in landed) (work.attempt, work.position): work,
        },
        groups: groups,
        shown: shown,
      ),
      current,
      account,
    );
    _queues[strategy.digest] = loaded;
    if (_disagreement(
          strategy,
          current.shown,
          membership: true,
          pages: strategy.loadedPages,
        )
        case final reason?) {
      _refuse(strategy, reason);
      return _QueueLoaded(loaded);
    }
    if (_summaries[strategy.digest] case final summary?) {
      _keepInMemory(
        strategy.digest,
        summary.withSync(_syncOf(account, current, _cloudNow())),
      );
    }
    _checked(strategy.digest, listed);
    return _QueueLoaded(loaded);
  }

  void _checked(String digest, StrategySummary? listed) {
    final wasUnchecked = _unchecked.remove(digest);
    if (_summaries[digest] case final summary?
        when wasUnchecked || summary != listed) {
      _emit(
        StrategyRefreshed(strategyPublicId: summary.publicId, summary: summary),
      );
    }
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
    if (_refusedThisSession[strategy.digest] case final reason?) {
      return _CloudRefused(StoredRowsDisagree(reason));
    }
    return switch (await _queueOf(strategy)) {
      _QueueLoaded() when _refusedThisSession.containsKey(strategy.digest) =>
        _CloudRefused(
          StoredRowsDisagree(_refusedThisSession[strategy.digest]!),
        ),
      _QueueLoaded(:final queue) => _CloudReady(strategy, header, queue),
      _QueueHeld(:final rows, :final owner) => _CloudHeld(
        strategy,
        header,
        rows,
        owner,
      ),
      _QueueNotRead(:final failure) => _CloudUnread(failure),
    };
  }

  void _forgetCloud(String digest) {
    _strategies.remove(digest);
    _queues.remove(digest);
  }

  void _refuse(LoadedStrategy strategy, String reason) {
    _refusedThisSession[strategy.digest] = reason;
    _forgetCloud(strategy.digest);
    if (strategy.strategyId case final id?) {
      _emit(
        StrategyRefused(
          strategyPublicId: id,
          refusal: StoredRowsDisagree(reason),
        ),
      );
    }
  }

  Future<Stored<void>> _checkedPages(
    LoadedStrategy strategy,
    Iterable<String> pageDigests,
  ) async {
    final queue = _queues[strategy.digest];
    if (queue == null) {
      throw StateError('a cloud page is checked against a queue not loaded');
    }
    for (final digest in pageDigests) {
      if (strategy.isLoaded(digest) || !strategy.hasPageRow(digest)) continue;
      switch (await _readPage(strategy, digest)) {
        case StorageFailed(:final failure):
          return StorageFailed(failure);
        case Done(value: final page):
          if (_pageDisagreement(
                strategy.pageIdOf(digest)!,
                page,
                queue.current.shown,
              )
              case final reason?) {
            _refuse(strategy, reason);
            throw _RowsDisagree(reason);
          }
          _addPage(strategy, digest, page);
      }
    }
    return done;
  }

  StrategyRowSet _baseRows(
    LoadedStrategy strategy,
    ReadableStrategy header,
    Iterable<String> digests,
  ) {
    final elements = <ElementRow>[];
    final groups = <LineupGroupRow>[];
    for (final digest in digests) {
      if (strategy.loadedPage(digest) case final loaded?) {
        elements.addAll(loaded.elements.values);
        groups.addAll(loaded.lineupGroups.values);
        storeWork.rowsDrawn +=
            loaded.elements.length + loaded.lineupGroups.length;
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
    final digests = [
      for (final digest in _wantedPages(strategy, queue, pages))
        if (strategy.hasPageRow(digest)) digest,
    ];
    final loaded = queue == null
        ? await _loadUnchecked(strategy, digests)
        : await _checkedPages(strategy, digests);
    if (loaded case StorageFailed(:final failure)) {
      return StorageFailed(failure);
    }
    final base = _baseRows(strategy, header, digests);
    if (queue == null) return Done(base);
    return Done(_throughReader(base, visibleOver(base, queue, pages)));
  }

  Set<String> _wantedPages(
    LoadedStrategy strategy,
    CloudQueue? queue,
    Pages pages,
  ) => switch ((queue, pages)) {
    (_, AllPages()) => strategy.pageDigests,
    (null, SomePages(:final pages)) => {
      for (final page in pages) digestOf(page),
    },
    (final queue?, SomePages(pages: final asked)) => {
      for (final page in {
        ...pagesToLoad(queue, pages),
        for (final entry in entriesForPages(queue, asked).$1)
          ..._pagesShowingRow(strategy, queue, targetOf(entry.op)),
        for (final work in queue.landed)
          ..._pagesShowingRow(strategy, queue, targetOf(work.op)),
      })
        digestOf(page),
    },
  };
  StrategyRowSet _throughReader(StrategyRowSet base, StrategyRowSet drawn) {
    final everywhere = RowSpot(names: (_) => true);
    Admission stored(Row row) => admit(canonicalJson(row.toJson()));
    final checked = <Row>[
      for (final row in drawn.elements)
        if (row case final LiveElement live
            when !identical(base.element(live.publicId), live) &&
                !_canRead.element(live.payload))
          if (ElementRow.parse(
                stored(live),
                spot: everywhere,
                page: everywhere,
                canRead: _canRead.element,
              )
              case Placed(:final row))
            row,
      for (final row in drawn.lineupGroups)
        if (row case final LiveLineupGroup live
            when !identical(base.lineupGroup(live.publicId), live) &&
                !_canRead.lineupGroup(live.payload))
          if (LineupGroupRow.parse(
                stored(live),
                spot: everywhere,
                page: everywhere,
                strategy: everywhere,
                canRead: _canRead.lineupGroup,
              )
              case Placed(:final row))
            row,
    ];
    return checked.isEmpty ? drawn : drawn.withRows(checked);
  }

  ({List<_Write> writes, Set<String> pages}) _queueWrites(
    LoadedStrategy strategy,
    _OnDisk disk,
    Account owner,
    CloudQueue next,
  ) {
    final area = strategy.area;
    final writes = <_Write>[];
    final pages = <String>{};
    Iterable<String> pagesOf(PendingOp entry) => {
      ...queuePagesOf(entry),
      ..._rowPages(strategy, entry.op),
    };
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
    if (next.strategy != disk.facts || owner != disk.owner) {
      writes.add(_PutFacts(area, owner, next.strategy));
    }
    final landed = {
      for (final work in next.landed) (work.attempt, work.position): work,
    };
    for (final MapEntry(key: at, value: work) in landed.entries) {
      if (disk.landed[at] != work) writes.add(_PutLanded(area, work));
      if (!disk.landed.containsKey(at)) {
        pages.addAll([
          ...pagesNeeded(work.op),
          ..._rowPages(strategy, work.op),
        ]);
      }
    }
    for (final MapEntry(key: at, value: work) in disk.landed.entries) {
      if (!landed.containsKey(at)) {
        writes.add(_DeleteName(area, LandedName(at.$1, at.$2).name));
        pages.addAll([
          ...pagesNeeded(work.op),
          ..._rowPages(strategy, work.op),
        ]);
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

  void _written(
    _OnDisk disk,
    Account owner,
    CloudQueue next,
    Map<String?, String> groups,
    Map<String?, String> encoded,
  ) {
    disk.entries
      ..clear()
      ..addAll({for (final entry in next.entries) entry.place: entry});
    disk.attempts
      ..clear()
      ..addAll(next.attempts);
    disk.owner = owner;
    disk.facts = next.strategy;
    disk.landed
      ..clear()
      ..addAll({
        for (final work in next.landed) (work.attempt, work.position): work,
      });
    disk.groups
      ..clear()
      ..addAll(groups);
    disk.encodedThisRun
      ..clear()
      ..addAll(encoded);
    disk.shown = next.shown;
  }

  Future<Stored<StrategySummary>> _cloudSummaryAll(
    LoadedStrategy strategy,
    ReadableStrategy header,
    Account owner,
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
            page.publicId: _tallyOn(strategy, rows, page.publicId),
        },
        elsewhere: strategy.elsewhere,
        sync: _syncOf(owner, queue, _cloudNow()),
      ),
    );
  }

  Future<Stored<_BaseApplied>> _applyBase(
    LoadedStrategy strategy,
    List<RowDecision> decisions,
  ) async {
    final area = strategy.area;
    final checked = <String>{};
    final leaving = <String>{};
    final items = _ItemDigests(strategy);
    for (final decision in decisions) {
      switch (decision) {
        case RowTaken(row: final ElementRow row):
          checked
            ..add(items.of(row.pagePublicId))
            ..addAll(strategy.pagesOfElementAt(items.of(row.publicId)));
        case RowTaken(row: final LineupGroupRow row):
          checked
            ..add(items.of(row.pagePublicId))
            ..addAll(strategy.pagesOfLineupGroupAt(items.of(row.publicId)));
        case RowUnchanged(row: ElementRow(:final pagePublicId)) ||
            RowUnchanged(row: LineupGroupRow(:final pagePublicId)):
          checked.add(items.of(pagePublicId));
        case ItemLeft(:final page) || UnreadableLeft(:final page):
          checked.add(items.of(page));
        case PageLeft(:final page):
          leaving.add(items.of(page));
        case UnlistedLeft(:final listed):
          final kept = {for (final page in listed) digestOf(page)};
          leaving.addAll([
            for (final digest in strategy.pageDigests)
              if (!kept.contains(digest)) digest,
          ]);
        case RowTaken() || RowKept() || RowUnchanged() || SettingsLeft():
          break;
      }
    }
    if (await _checkedPages(strategy, {...checked, ...leaving})
        case StorageFailed(:final failure)) {
      return StorageFailed(failure);
    }
    for (final digest in {...checked, ...leaving}) {
      items.learnPage(digest);
    }
    final before = <String, (StoreName, Held)>{};
    final gone = <String>{};
    final pages = <String>{};
    final rows = <Target>{};
    Row? held(StoreName name) => switch (strategy.heldUnder(name)) {
      HeldRow(:final row) => row,
      HeldNothing() || HeldUnplaced() => null,
    };
    void remember(StoreName name) =>
        before.putIfAbsent(name.name, () => (name, strategy.heldUnder(name)));
    void drop(StoreName name) {
      remember(name);
      switch (held(name)) {
        case final ElementRow row:
          rows.add(ElementTarget(row.publicId));
          strategy.forgetRow(row);
        case final LineupGroupRow row:
          rows.add(LineupTarget(row.publicId));
          strategy.forgetRow(row);
        case final row?:
          strategy.forgetRow(row);
        case null:
          if (strategy.heldUnder(name) is HeldUnplaced) {
            gone.add(name.name);
            strategy.forgetUnplaced(name);
          }
      }
    }

    void dropPageAt(String digest) {
      if (strategy.pageIdOf(digest) case final page?) pages.add(page);
      remember(PageName(digest));
      remember(SettingsName(digest));
      if (strategy.loadedPage(digest) case final loaded?) {
        for (final row in loaded.elements.values) {
          remember(nameOf(row));
          rows.add(ElementTarget(row.publicId));
        }
        for (final row in loaded.lineupGroups.values) {
          remember(nameOf(row));
          rows.add(LineupTarget(row.publicId));
        }
        for (final row in loaded.unplaced.values) {
          gone.add(row.ref.name);
        }
        for (final row in loaded.unknownKinds) {
          gone.add(row.key);
        }
      }
      for (final name in [PageName(digest), SettingsName(digest)]) {
        if (strategy.heldUnder(name) is HeldUnplaced) {
          gone.add(name.name);
          strategy.forgetUnplaced(name);
        }
      }
      strategy.forgetPage(digest);
    }

    void put(Row row) {
      final name = nameOf(row);
      remember(name);
      switch (row) {
        case ElementRow(:final publicId):
          rows.add(ElementTarget(publicId));
        case LineupGroupRow(:final publicId):
          rows.add(LineupTarget(publicId));
        case _:
          break;
      }
      if (row case PageRow(:final publicId)) {
        final page = digestOf(publicId);
        if (!strategy.hasPageRow(page) && !strategy.isLoaded(page)) {
          strategy.addLoadedPage(page, LoadedPage());
        }
      }
      strategy.keepRow(row);
      switch (row) {
        case ElementRow(pagePublicId: final publicId) ||
            LineupGroupRow(pagePublicId: final publicId):
          pages.add(publicId);
        case _:
          break;
      }
    }

    StoreName itemName(Target target, String page) => switch (target) {
      ElementTarget(:final elementPublicId) => ElementName(
        items.of(page),
        items.of(elementPublicId),
      ),
      LineupTarget(:final lineupPublicId) => LineupName(
        items.of(page),
        items.of(lineupPublicId),
      ),
      _ => throw StateError('$target is not an item on a page'),
    };

    for (final decision in decisions) {
      switch (decision) {
        case RowTaken(:final row):
          put(row);
        case RowKept():
          break;
        case ItemLeft(:final target, :final page):
          drop(itemName(target, page));
          pages.add(page);
        case RowUnchanged(:final row):
          switch (strategy.heldUnder(items.nameOf(row))) {
            case HeldRow(row: final held)
                when shownTakesChecked &&
                    !sameJsonTree(held.toJsonView(), row.toJsonView()):
              final reason =
                  '${row.key} holds other contents here than a result the '
                  'queue found unchanged';
              _refuse(strategy, reason);
              throw _RowsDisagree(reason);
            case HeldRow():
              break;
            case HeldNothing() || HeldUnplaced():
              throw TakesDiffer.missing('${row.key}');
          }
        case PageLeft(:final page):
          dropPageAt(digestOf(page));
        case UnlistedLeft(:final listed):
          final kept = {for (final page in listed) digestOf(page)};
          for (final digest in [...strategy.pageDigests]) {
            if (!kept.contains(digest)) dropPageAt(digest);
          }
          for (final name in [...strategy.unplaced.keys]) {
            final digest = name.split('/').last;
            if (kept.contains(digest)) continue;
            gone.add(name);
            strategy.unplaced.remove(name);
          }
        case SettingsLeft(:final page):
          drop(SettingsName(items.of(page)));
        case UnreadableLeft(:final page):
          if (strategy.loadedPage(items.of(page)) case final loaded?) {
            for (final row in loaded.unknownKinds) {
              gone.add(row.key);
            }
            loaded.unknownKinds.clear();
          }
          pages.add(page);
      }
    }
    if (shownTakesChecked) {
      for (final target in rows) {
        final copies = switch (target) {
          ElementTarget(:final elementPublicId) => strategy.pagesOfElement(
            elementPublicId,
          ),
          LineupTarget(:final lineupPublicId) => strategy.pagesOfLineupGroup(
            lineupPublicId,
          ),
          _ => const <String>[],
        };
        if (copies.length > 1) throw TakesDiffer.copies('$target');
      }
    }
    final writes = <_Write>[
      for (final name in gone) _DeleteName(area, name),
      for (final (name, was) in before.values)
        ...switch ((was, held(name))) {
          (HeldRow(:final row), final now?) when _comparedEqual(now, row) =>
            const <_Write>[],
          (_, final now?) => [_PutRow(area, now)],
          (HeldRow() || HeldUnplaced(), null) => [_DeleteName(area, name.name)],
          (HeldNothing(), null) => const <_Write>[],
        },
    ];
    return Done((writes: writes, pages: pages, rows: rows));
  }

  Future<Saving<T, CommitRefusal>> _finishCloud<T>(
    _CloudReady cloud,
    CloudQueue proposed,
    List<RowDecision> decisions,
    Set<String> edited,
    T Function(StrategySummary summary) take,
  ) async {
    final strategy = cloud.strategy;
    final digest = strategy.digest;
    final area = strategy.area;
    final disk = cloud.queue.disk;
    final numbersBefore = _numbers;
    void asBefore() {
      _strategies.remove(digest);
      _numbers = numbersBefore;
    }

    try {
      final next = proposed;
      final _BaseApplied base;
      switch (await _applyBase(strategy, decisions)) {
        case StorageFailed(:final failure):
          asBefore();
          return NotSaved(failure);
        case Done(:final value):
          base = value;
      }
      final owner = cloud.queue.owner;
      final queued = _queueWrites(strategy, disk, owner, next);
      final unchanged = identical(next.shown, disk.shown);
      final groups = unchanged
          ? {...disk.groups}
          : _groupTextsSince(
              shownTakesReuse ? disk.shown : Shown.nothing,
              shownTakesReuse ? disk.encodedThisRun : const {},
              next.shown,
            );
      final encoded = unchanged ? {...disk.encodedThisRun} : groups;
      final header = _baseHeader(strategy, cloud.header);
      final previous = _summaries[digest];
      final StrategySummary summary;
      if (previous == null) {
        switch (await _cloudSummaryAll(strategy, header, owner, next)) {
          case StorageFailed(:final failure):
            asBefore();
            return NotSaved(failure);
          case Done(:final value):
            summary = value;
        }
      } else {
        final changedPages = {...base.pages, ...queued.pages, ...edited};
        final cachedOnChanged = [
          for (final page in changedPages)
            if (strategy.hasPageRow(digestOf(page))) digestOf(page),
        ];
        if (await _checkedPages(strategy, cachedOnChanged) case StorageFailed(
          :final failure,
        )) {
          asBefore();
          return NotSaved(failure);
        }
        final loadedRows = <Target, Iterable<String>>{
          for (final digest in cachedOnChanged)
            if (strategy.loadedPage(digest) case final loaded?) ...{
              for (final MapEntry(key: id, value: row)
                  in loaded.elements.entries)
                ElementTarget(row.publicId): strategy.pagesOfElementAt(id),
              for (final MapEntry(key: id, value: row)
                  in loaded.lineupGroups.entries)
                LineupTarget(row.publicId): strategy.pagesOfLineupGroupAt(id),
            },
        };
        final changedRows = {
          ...base.rows,
          for (final entry in next.entries)
            if (entry is PendingOp && pagesOf(entry).any(changedPages.contains))
              targetOf(entry.op),
          for (final work in next.landed)
            if (pagesNeeded(work.op).any(changedPages.contains))
              targetOf(work.op),
        };
        final touched = {
          ...changedPages,
          for (final MapEntry(key: target, value: pages)
              in loadedRows.entries) ...{
            for (final digest in pages) ?strategy.pageIdOf(digest),
            ...pagesShowing(next, target),
          },
          for (final target in changedRows)
            if (!loadedRows.containsKey(target))
              ..._pagesShowingRow(strategy, next, target),
        };
        final StrategyRowSet rows;
        switch (await _visibleFor(strategy, header, next, SomePages(touched))) {
          case StorageFailed(:final failure):
            asBefore();
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
              asBefore();
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
                  ? _tallyOn(strategy, all, page.publicId)
                  : previous.tallies[page.publicId]!,
          },
          elsewhere: strategy.elsewhere,
          sync: _syncOf(owner, next, _cloudNow()),
        );
      }
      final numbers = _higher(_numbers, _numbersOf(next));
      final writes = [
        ...base.writes,
        ...queued.writes,
        ..._resultWrites(area, disk, groups),
        if (_numbersRow != _NumbersRowRead(numbers)) _PutNumbers(numbers),
        if (summary != previous || _unsaved.contains(digest))
          _PutSummary(digest, summary),
      ];
      _numbers = numbers;
      if (writes.isEmpty) {
        cloud.queue.current = next;
        _sessions[digest] = (session: next.session, shown: next.shown);
        return Saved(take(summary));
      }
      final result = await _commit<T, CommitRefusal>(writes, () {
        _written(disk, owner, next, groups, encoded);
        cloud.queue.current = next;
        _sessions[digest] = (session: next.session, shown: next.shown);
        _summaries[digest] = summary;
        _unsaved.remove(digest);
        _numbersRow = _NumbersRowRead(numbers);
        return take(summary);
      });
      switch (result) {
        case Saved() || NothingToSave():
          break;
        case NotSaved() || Refused():
          asBefore();
        case SaveInDoubt():
          _forgetCloud(digest);
      }
      return result;
    } catch (_) {
      asBefore();
      rethrow;
    }
  }

  Set<String> _ownPages(
    LoadedStrategy strategy,
    CloudQueue queue,
    StrategyOp op,
  ) => {
    ...pagesNeeded(op),
    ..._pagesShowingRow(strategy, queue, targetOf(op)),
    for (final entry in queue.entries)
      if (entry is PendingOp && targetOf(entry.op) == targetOf(op))
        ...pagesOf(entry),
  };

  Future<BatchResult> _commitOfAnotherLife(
    _CloudReady cloud,
    CloudQueue start,
    List<StrategyOp> asked,
    int? madeOn,
    DateTime now,
  ) async {
    var queue = start;
    for (final op in asked) {
      switch (transition(
        queue,
        EditOfAnotherLife(editOfAnotherLife(op), madeOn: madeOn),
        now: now,
      )) {
        case NotApplicable(:final why):
          return Refused(QueueRefusal(why));
        case Stepped(queue: final stepped):
          queue = stepped;
      }
    }
    return switch (await _finishCloud(
      cloud,
      queue,
      const [],
      const {},
      (summary) => const <Committed>[],
    )) {
      Saved() => Refused(
        EditOfAReplacedStrategy(cloud.header.publicId, [
          for (final op in asked) op.opId,
        ]),
      ),
      NothingToSave() => const NothingToSave(),
      Refused(:final reason) => Refused(reason),
      NotSaved(:final failure) => NotSaved(failure),
      SaveInDoubt(:final failure) => SaveInDoubt(failure),
    };
  }

  Future<BatchResult> _commitCloud(
    _CloudReady cloud,
    List<StrategyOp> asked, {
    required int? madeOn,
  }) async {
    final strategy = cloud.strategy;
    final now = _cloudNow();
    var queue = cloud.queue.current.raisedTo(
      nextAttempt: _numbers.nextAttempt,
      nextSession: _numbers.nextSession,
    );
    if (queue.shown.strategy?.life case final recordLife?
        when recordLife != madeOn) {
      return _commitOfAnotherLife(cloud, queue, asked, madeOn, now);
    }
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
        case PageAddOp(copyContentFromPagePublicId: final source?)
            when !queue.shown.content.containsKey(source):
          return Refused(CopyNeedsContent(source));
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
        switch (transition(queue, UserEdited(edit, madeOn: madeOn), now: now)) {
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

  CommitRefusal? _anotherAccount(
    String strategyPublicId,
    CloudOwner owner,
    Account asking,
  ) => switch (owner) {
    OwnedBy(:final account) when account != asking => WorkOfAnotherAccount(
      strategyPublicId,
      owner,
    ),
    _ => null,
  };

  CommitRefusal? _anotherAccountOpened(
    String strategyPublicId,
    _CloudOpen open,
    Account asking,
  ) => switch (open) {
    _CloudReady(:final queue) => _anotherAccount(
      strategyPublicId,
      OwnedBy(queue.owner),
      asking,
    ),
    _CloudHeld(:final owner) => _anotherAccount(
      strategyPublicId,
      owner,
      asking,
    ),
    _CloudRefused() || _CloudUnread() => null,
  };

  Future<RecordResult> _recordCloud(
    Account asking,
    String strategyPublicId,
    List<QueueEvent> events,
  ) async {
    final open = await _openCloud(strategyPublicId);
    if (_anotherAccountOpened(strategyPublicId, open, asking)
        case final refusal?) {
      return Refused(refusal);
    }
    if (open is! _CloudRefused && open is! _CloudUnread) {
      if (_unfitResult(strategyPublicId, events) case final refusal?) {
        return Refused(refusal);
      }
    }
    final _CloudReady cloud;
    switch (open) {
      case _CloudRefused(:final refusal):
        return Refused(refusal);
      case _CloudHeld(:final rows):
        return Refused(QueueHeld(rows));
      case _CloudUnread(:final failure):
        return NotSaved(failure);
      case final _CloudReady ready:
        cloud = ready;
    }
    try {
      return await _recordOn(cloud, events);
    } on _RowsDisagree catch (disagreement) {
      return Refused(StoredRowsDisagree(disagreement.reason));
    }
  }

  Future<BatchResult> _commitRefusingOnDisagreement(
    _CloudReady cloud,
    List<StrategyOp> asked, {
    required int? madeOn,
  }) async {
    try {
      return await _commitCloud(cloud, asked, madeOn: madeOn);
    } on _RowsDisagree catch (disagreement) {
      return Refused(StoredRowsDisagree(disagreement.reason));
    }
  }

  Future<_Rebuilt> _cloudRebuilt(
    LoadedStrategy strategy,
    ReadableStrategy header,
    _LoadedQueue queue,
  ) async {
    _RebuiltSummary refused() => _RebuiltSummary(
      StrategySummary.of(
        strategy: header,
        pages: strategy.pages,
        settings: strategy.allSettings,
        tallies: _summaries[strategy.digest]?.tallies ?? const {},
        elsewhere: strategy.elsewhere,
      ).withSync(_heldSync(OwnedBy(queue.owner), const [])),
    );
    if (_refusedThisSession.containsKey(strategy.digest)) return refused();
    try {
      return switch (await _cloudSummaryAll(
        strategy,
        header,
        queue.owner,
        queue.current,
      )) {
        Done(:final value) => _RebuiltSummary(value),
        StorageFailed(:final failure) => _RebuildNotRead(failure),
      };
    } on _RowsDisagree {
      return refused();
    }
  }

  Future<RecordResult> _recordOn(
    _CloudReady cloud,
    List<QueueEvent> events,
  ) async {
    final strategyPublicId = cloud.header.publicId;
    if (_unfitResult(strategyPublicId, events) case final refusal?) {
      return Refused(refusal);
    }
    final now = _cloudNow();
    final outcomes = <ReportOutcome>[];
    final decisions = <RowDecision>[];
    var queue = recordExpiries(
      cloud.queue.current.raisedTo(
        nextAttempt: _numbers.nextAttempt,
        nextSession: _numbers.nextSession,
      ),
      now,
    );
    for (final event in events.map(_atStoredPrecision)) {
      if (event is UserEdited) {
        outcomes.add(const EditsGoThroughCommit());
        continue;
      }
      if (event case BaseArrived(
        :final from,
      ) when !(_cloudResults?.takes(from) ?? false)) {
        outcomes.add(ReportNotApplicable(NotThisModesResults(_cloudResults)));
        continue;
      }
      final step = transition(queue, event, now: now);
      queue = step.queue;
      switch (step) {
        case NotApplicable(:final why):
          outcomes.add(ReportNotApplicable(why));
        case Stepped(:final effects, decisions: final taken):
          decisions.addAll(taken);
          outcomes.add(ReportApplied(effects));
      }
    }
    final result = await _finishCloud(
      cloud,
      queue,
      decisions,
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

  String? _disagreement(
    LoadedStrategy strategy,
    Shown shown, {
    required bool membership,
    required Iterable<String> pages,
  }) {
    String? item(Target target) => switch (target) {
      ElementTarget(:final elementPublicId) => elementPublicId,
      LineupTarget(:final lineupPublicId) => lineupPublicId,
      _ => null,
    };
    if (membership) {
      if ((shown.strategy, strategy.header) case (
        final held?,
        HeaderPlaced(row: final ReadableStrategy stored),
      ) when held.version != versionOfRow(stored)) {
        return 'the strategy row is at ${versionOfRow(stored)} here and at '
            '${held.version} in the queue';
      }
      if (strategy.unplaced.isNotEmpty) {
        return 'a page or settings row is damaged here';
      }
      final live = {
        for (final row in strategy.pages)
          if (lifeOfRow(row) == Life.live) row.publicId: versionOfRow(row),
      };
      for (final MapEntry(key: page, value: row) in shown.pages.entries) {
        if (!live.containsKey(page)) {
          return 'page $page is live in the queue and not here';
        }
        if (live[page] != row.version) {
          return 'page $page is at ${live[page]} here and at ${row.version} '
              'in the queue';
        }
      }
      for (final page in live.keys) {
        if (!shown.pages.containsKey(page)) {
          return 'page $page is live here and not in the queue';
        }
      }
      final settings = {
        for (final row in strategy.allSettings)
          row.pagePublicId: versionOfRow(row),
      };
      if (settings.length != shown.settings.length) {
        return 'the settings held here are not the ones the queue holds';
      }
      for (final MapEntry(key: page, value: row) in shown.settings.entries) {
        if (!settings.containsKey(page) || settings[page] != row.version) {
          return 'the settings of page $page are at ${settings[page]} here '
              'and at ${row.version} in the queue';
        }
      }
      final pageDigests = <String, String>{};
      final named = <(bool, String), String>{};
      for (final MapEntry(key: target, value: row) in shown.rows.entries) {
        if (item(target) case final id?) {
          named[(target is LineupTarget, digestOf(id))] =
              pageDigests[row.page] ??= digestOf(row.page);
        }
      }
      for (final (lineup, index) in [
        (false, strategy.elementIndex),
        (true, strategy.lineupIndex),
      ]) {
        for (final MapEntry(key: digest, value: on) in index.entries) {
          if (on.isEmpty) continue;
          final expected = named[(lineup, digest)];
          if (expected == null) {
            return 'an item is held here that the queue does not hold';
          }
          if (on.length != 1 || on.single != expected) {
            return 'an item is held here on another page than in the queue, '
                'or on more than one';
          }
          if (!strategy.hasPageRow(expected)) {
            return 'an item is held on a page with no page row here';
          }
        }
      }
      for (final (lineup, digest) in named.keys) {
        final index = lineup ? strategy.lineupIndex : strategy.elementIndex;
        if (index[digest]?.isNotEmpty != true) {
          return 'the queue holds an item that has no copy here';
        }
      }
    }
    for (final digest in pages) {
      final page = strategy.pageIdOf(digest);
      final loaded = strategy.loadedPage(digest);
      if (page == null || loaded == null) continue;
      if (_pageDisagreement(page, loaded, shown) case final reason?) {
        return reason;
      }
    }
    return null;
  }

  static String? _pageDisagreement(
    String page,
    LoadedPage loaded,
    Shown shown,
  ) {
    if (loaded.unplaced.isNotEmpty) {
      return 'a row on page $page is damaged here';
    }
    for (final row in <Row>[
      ...loaded.elements.values,
      ...loaded.lineupGroups.values,
    ]) {
      final target = switch (row) {
        ElementRow(:final publicId) => ElementTarget(publicId) as Target,
        LineupGroupRow(:final publicId) => LineupTarget(publicId),
        _ => throw StateError('only items are stored on a page'),
      };
      final held = shown.rows[target];
      if (held?.version != versionOfRow(row)) {
        return '$target is at ${versionOfRow(row)} here and at '
            '${held?.version} in the queue';
      }
      if (shownTakesChecked &&
          held != null &&
          held.digestedThisRun &&
          held.digest != rowDigest(row)) {
        return '$target holds other contents here than the queue holds';
      }
    }
    return null;
  }

  CloudStrategy _syncView(_LoadedQueue loaded) => CloudStrategy(
    owner: loaded.owner,
    queue: loaded.current,
    views: entryViews(loaded.current, _cloudNow()),
    tally: Tally.of(loaded.current, _cloudNow()),
  );

  Future<Reading<T>> _cloudReading<T>(
    LoadedStrategy loaded,
    String strategyPublicId,
    Future<Reading<T>> Function(_CloudOpen cloud) read,
  ) async {
    InUnreadableStrategy<T> refused(CommitRefusal refusal) =>
        InUnreadableStrategy(
          UnreadableStrategyListing(
            ref: StrategyRef(loaded.area),
            header: loaded.header,
            refused: refusal,
          ),
        );
    try {
      return switch (await _openCloud(strategyPublicId)) {
        final _CloudReady cloud => await read(cloud),
        final _CloudHeld cloud => await read(cloud),
        _CloudUnread(:final failure) => NotRead(failure),
        _CloudRefused(:final refusal) => refused(refusal),
      };
    } on _RowsDisagree catch (disagreement) {
      return refused(StoredRowsDisagree(disagreement.reason));
    }
  }

  Future<Reading<StrategyContent>> _readCloudStrategy(_CloudOpen cloud) =>
      switch (cloud) {
        _CloudReady(:final strategy, :final header, :final queue) =>
          _cloudStrategyContent(
            strategy,
            header,
            queue.current,
            _syncView(queue),
          ),
        _CloudHeld(:final strategy, :final header, :final rows, :final owner) =>
          _cloudStrategyContent(strategy, header, null, CloudHeld(owner, rows)),
        _CloudRefused() || _CloudUnread() => throw StateError('not open'),
      };

  Future<Reading<StrategyContent>> _cloudStrategyContent(
    LoadedStrategy strategy,
    ReadableStrategy header,
    CloudQueue? queue,
    StrategySync sync,
  ) async {
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
  ) => switch (cloud) {
    _CloudReady(:final strategy, :final header, :final queue) =>
      _cloudPageContent(
        strategy,
        header,
        queue.current,
        pagePublicId,
        sync: _syncView(queue),
        content: queue.current.shown.content.containsKey(pagePublicId)
            ? const ContentShown()
            : const ContentNotRead(),
      ),
    _CloudHeld(:final strategy, :final header, :final rows, :final owner) =>
      _cloudPageContent(
        strategy,
        header,
        null,
        pagePublicId,
        sync: CloudHeld(owner, rows),
        content: const ContentNotRead(),
      ),
    _CloudRefused() || _CloudUnread() => throw StateError('not open'),
  };

  Future<Reading<PageContent>> _cloudPageContent(
    LoadedStrategy strategy,
    ReadableStrategy header,
    CloudQueue? queue,
    String pagePublicId, {
    required StrategySync sync,
    required PageContentState content,
  }) async {
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
    _countedAsDrawn(strategy, rows, pagePublicId);
    final loaded = strategy.loadedPage(digestOf(pagePublicId));
    return Found(
      PageContent(
        strategyLife: header.createdAt.millisecondsSinceEpoch,
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
        content: content,
      ),
    );
  }

  void _countedAsDrawn(
    LoadedStrategy strategy,
    StrategyRowSet rows,
    String pagePublicId,
  ) {
    final listed = _summaries[strategy.digest];
    if (listed == null) return;
    final drawn = _tallyOn(strategy, rows, pagePublicId);
    if ((listed.tallies[pagePublicId] ?? PageTally.empty) == drawn) return;
    final summary = StrategySummary.of(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      tallies: {...listed.tallies, pagePublicId: drawn},
      elsewhere: strategy.elsewhere,
      sync: listed.sync,
    );
    _keepInMemory(strategy.digest, summary);
    _emit(
      StrategyRefreshed(strategyPublicId: summary.publicId, summary: summary),
    );
  }

  Future<bool> _noCloudAreaStored() async {
    final List<String> areas;
    switch (await _lease.areas(strategyAreaPrefix)) {
      case StorageFailed():
        return false;
      case Done(:final value):
        areas = value;
    }
    for (final area in areas) {
      switch (await _lease.keys(area, '')) {
        case StorageFailed():
          return false;
        case Done(:final value) when value.any(isCloudKey):
          return false;
        case Done():
          break;
      }
    }
    return true;
  }

  Future<Saving<StrategySummary, LibraryRefusal>> _addCloud(
    Account account,
    HeaderRead header,
    List<PageRead> pages,
  ) async {
    final results = _cloudResults;
    if (results == null) return const Refused(CloudResultsNotChosen());
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
    switch (await _lease.keys(area, '')) {
      case StorageFailed(:final failure):
        return NotSaved(failure);
      case Done(:final value) when value.isNotEmpty:
        return Refused(StrategyAlreadyInStore(id));
      case Done():
        break;
    }
    switch (_numbersRow) {
      case _NumbersRowUnreadable():
        return const Refused(NumbersUnreadable());
      case _NoNumbersRow():
        if (_summaries.values.any((summary) => summary.sync is! KeptHere) ||
            !await _noCloudAreaStored()) {
          return const Refused(NumbersUnreadable());
        }
      case _NumbersRowRead():
        break;
    }
    final strategy = LoadedStrategy(
      digest: digest,
      header: const HeaderAbsent('none of its rows are stored'),
      strategyId: id,
      pages: const {},
      settings: const {},
      unplaced: const {},
      names: const [CloudName()],
    );
    var queue = CloudQueue.start(build: _build).raisedTo(
      nextAttempt: _numbers.nextAttempt,
      nextSession: _numbers.nextSession,
    );
    final now = _cloudNow();
    queue = transition(queue, const ConnectionReturned(), now: now).queue;
    final events = [
      for (final base in <ArrivedBase>[header, ...pages])
        BaseArrived(
          base,
          session: queue.session.number,
          from: switch (results) {
            CloudResults.liveQueries => const LiveResult(),
            CloudResults.thisDevicesReads =>
              ReadOfThisDevice(queue.session.readStart),
          },
        ),
    ];
    _forgetCloud(digest);
    _strategies[digest] = strategy;
    final loaded = _LoadedQueue(
      _OnDisk(
        entries: {},
        attempts: {},
        owner: null,
        facts: null,
        landed: {},
        groups: {},
        shown: Shown.nothing,
      ),
      queue,
      account,
    );
    _queues[digest] = loaded;
    final result = await _recordOn(
      _CloudReady(strategy, strategyRow, loaded),
      events,
    );
    switch (result) {
      case Saved():
        _unreadable.remove(digest);
        _unchecked.remove(digest);
        _refusedThisSession.remove(digest);
      case _:
        _forgetCloud(digest);
    }
    return switch (result) {
      Saved(:final value) => Saved(value.summary),
      NothingToSave() => const NothingToSave(),
      NotSaved(:final failure) => NotSaved(failure),
      SaveInDoubt(:final failure) => SaveInDoubt(failure),
      Refused(reason: final LibraryRefusal reason) => Refused(reason),
      Refused(:final reason) => throw StateError('$reason on import'),
    };
  }

  Future<Saving<StrategySummary, CommitRefusal>> _discardHeld(
    Account account,
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
    if (!keys.any(isCloudKey)) {
      return Refused(NotACloudStrategy(strategyPublicId));
    }
    final LoadedStrategy strategy;
    switch (await _strategyAt(digest)) {
      case Found(:final value):
        strategy = value;
      case NotFound():
        return Refused(NoSuchStrategy(strategyPublicId));
      case NotRead(:final failure):
        return NotSaved(failure);
      case InUnreadableStrategy(:final listing):
        return Refused(StrategyNotReadable(listing.ref));
    }
    final ReadableStrategy header;
    switch (strategy.header) {
      case HeaderPlaced(row: final ReadableStrategy row):
        header = row;
      case HeaderPlaced(row: final UnreadableStrategy row):
        return Refused(UnreadableRowInTheWay(row));
      case HeaderUnplaced() || HeaderAbsent():
        return Refused(StrategyNotReadable(StrategyRef(strategy.area)));
    }
    switch (await _queueOf(strategy)) {
      case _QueueNotRead(:final failure):
        return NotSaved(failure);
      case _QueueLoaded(:final queue):
        return Refused(
          _anotherAccount(strategyPublicId, OwnedBy(queue.owner), account) ??
              QueueNotHeld(strategyPublicId),
        );
      case _QueueHeld(:final owner):
        switch (owner) {
          case OwnedBy(account: final whose) when whose == account:
            break;
          case OwnedBy():
            return Refused(WorkOfAnotherAccount(strategyPublicId, owner));
          case OwnerUnreadable():
            return Refused(OwnerNotRead(strategyPublicId));
        }
    }
    final summary =
        StrategySummary.of(
          strategy: header,
          pages: const [],
          settings: const [],
          tallies: const {},
          elsewhere: strategy.elsewhere,
        ).withSync(switch (_numbersHold) {
          final row? => _heldSync(OwnedBy(account), [row]),
          null => _syncOf(
            account,
            CloudQueue.start(build: _build),
            _cloudNow(),
          ),
        });
    final result = await _commit<StrategySummary, CommitRefusal>(
      [
        for (final key in keys)
          if (key != const HeaderName().name && key != const CloudName().name)
            _DeleteName(area, key),
        _PutFacts(area, account, StrategyFacts.fresh),
        _PutSummary(digest, summary),
      ],
      () {
        _summaries[digest] = summary;
        _unsaved.remove(digest);
        _refusedThisSession.remove(digest);
        return summary;
      },
    );
    _forgetCloud(digest);
    return result;
  }
}
