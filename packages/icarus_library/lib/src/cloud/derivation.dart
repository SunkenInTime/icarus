part of 'queue.dart';

final class DerivationWork {
  int views = 0;
  int visits = 0;

  void reset() {
    views = 0;
    visits = 0;
  }
}

final derivationWork = DerivationWork();

typedef _Slot = (int, String);

final class _Keys {
  _Keys({required this.under, required this.read});

  final List<Object> under;
  final List<Object> read;

  Iterable<Object> get published => under;
}

final _keysCache = Expando<_Keys>();
final _pagesCache = Expando<Set<String>>();
final _oversizedCache = Expando<bool>();

Set<String> _pagesOf(PendingOp entry) =>
    _pagesCache[entry] ??= Set.unmodifiable(pagesOf(entry));

bool _oversized(PendingOp entry) =>
    _oversizedCache[entry] ??= exceedsSizePolicy(entry.op.toJson());

String? _ownPage(StrategyOp op) => switch (op) {
  PageAddOp(:final pagePublicId) ||
  PageDeleteOp(:final pagePublicId) => pagePublicId,
  _ => null,
};

String? _workPage(StrategyOp op) => switch (op) {
  PageDeleteOp(:final pagePublicId) => pagePublicId,
  _ => null,
};

_Keys _keysOf(PendingOp entry) => _keysCache[entry] ??= () {
  final op = entry.op;
  final target = targetOf(op);
  final pages = _pagesOf(entry);
  final own = _ownPage(op);
  final work = _workPage(op);
  return _Keys(
    under: [
      target,
      if (target is StrategyTarget || target is PageTarget) const _PageList(),
      if (renumbersPages(op)) const _Renumbering(),
      if (op is PagePatchOp) const _PagePatching(),
      ?switch (own) {
        final page? => _PageLife(page),
        null => null,
      },
      for (final page in pages) _OnPage(page),
    ],
    read: [
      target,
      if (target is PageTarget) const _Renumbering(),
      if (renumbersPages(op)) const _PagePatching(),
      for (final page in pages)
        if (page != own) _PageLife(page),
      ?switch (work) {
        final page? => _OnPage(page),
        null => null,
      },
    ],
  );
}();

final class _Renumbering {
  const _Renumbering();

  @override
  bool operator ==(Object other) => other is _Renumbering;

  @override
  int get hashCode => (_Renumbering).hashCode;
}

final class _PageList {
  const _PageList();

  @override
  bool operator ==(Object other) => other is _PageList;

  @override
  int get hashCode => (_PageList).hashCode;
}

final class _PagePatching {
  const _PagePatching();

  @override
  bool operator ==(Object other) => other is _PagePatching;

  @override
  int get hashCode => (_PagePatching).hashCode;
}

final class _PageLife {
  const _PageLife(this.page);

  final String page;

  @override
  bool operator ==(Object other) => other is _PageLife && other.page == page;

  @override
  int get hashCode => Object.hash(_PageLife, page);
}

final class _OnPage {
  const _OnPage(this.page);

  final String page;

  @override
  bool operator ==(Object other) => other is _OnPage && other.page == page;

  @override
  int get hashCode => Object.hash(_OnPage, page);
}

int _slotAt(List<_Slot> slots, int place) {
  var low = 0;
  var high = slots.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (slots[middle].$1 < place) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

final class _Index {
  _Index({
    required this.byId,
    required this.under,
    required this.readers,
    required this.attemptsByOp,
    required this.forgetAt,
    required this.forgetDays,
  });

  factory _Index.of(List<QueueEntry> entries, Map<int, AttemptFact> attempts) {
    final edit = _IndexEdit(_Index.empty);
    for (final entry in entries) {
      edit.add(entry);
    }
    final numbers = attempts.keys.toList()..sort();
    for (final number in numbers) {
      edit.addAttempt(attempts[number]!);
    }
    return edit.build();
  }

  DateTime? get firstForgetting => switch (forgetDays.keys) {
    final days when days.isEmpty => null,
    final days => DateTime.fromMillisecondsSinceEpoch(
      forgetDays[days.reduce((a, b) => a < b ? a : b)]!.first.$1,
      isUtc: true,
    ),
  };

  static final empty = _Index(
    byId: const {},
    under: const {},
    readers: const {},
    attemptsByOp: const {},
    forgetAt: const {},
    forgetDays: const {},
  );

  final Map<String, QueueEntry> byId;
  final Map<Object, List<_Slot>> under;
  final Map<Object, List<_Slot>> readers;
  final Map<String, List<int>> attemptsByOp;
  final Map<String, int> forgetAt;
  final Map<int, List<_Slot>> forgetDays;

  List<String> dueBy(DateTime now) {
    final millis = now.millisecondsSinceEpoch;
    final today = millis ~/ Duration.millisecondsPerDay;
    final due = <String>[];
    for (final MapEntry(key: day, value: list) in forgetDays.entries) {
      derivationWork.visits++;
      if (day > today) continue;
      for (final (at, id) in list) {
        if (at > millis) break;
        derivationWork.visits++;
        due.add(id);
      }
    }
    return due;
  }

  String? lastBefore(Map<Object, List<_Slot>> lists, Object key, int place) {
    final slots = lists[key];
    if (slots == null) return null;
    final at = _slotAt(slots, place);
    derivationWork.visits++;
    return at == 0 ? null : slots[at - 1].$2;
  }

  Iterable<String> allBefore(Object key, int place) sync* {
    final slots = under[key];
    if (slots == null) return;
    final end = _slotAt(slots, place);
    for (var i = 0; i < end; i++) {
      derivationWork.visits++;
      yield slots[i].$2;
    }
  }

  bool anyAfter(Object key, int place) {
    final slots = under[key];
    if (slots == null) return false;
    derivationWork.visits++;
    return _slotAt(slots, place + 1) < slots.length;
  }

  Iterable<String> readersAfter(Object key, int place) sync* {
    final slots = readers[key];
    if (slots == null) return;
    for (var i = _slotAt(slots, place + 1); i < slots.length; i++) {
      derivationWork.visits++;
      yield slots[i].$2;
    }
  }

  Iterable<String> ids(Object key) sync* {
    for (final (_, id) in under[key] ?? const <_Slot>[]) {
      derivationWork.visits++;
      yield id;
    }
  }
}

final class _IndexEdit {
  _IndexEdit(this._from);

  final _Index _from;
  Map<String, QueueEntry>? _byId;
  Map<Object, List<_Slot>>? _under;
  Map<Object, List<_Slot>>? _readers;
  Map<String, List<int>>? _attemptsByOp;
  Map<String, int>? _forgetAt;
  Map<int, List<_Slot>>? _forgetDays;
  final _copied = <(int, Object)>{};
  final _copiedDays = <int>{};

  Map<String, QueueEntry> get byId => _byId ?? _from.byId;

  List<_Slot> underOf(Object key) =>
      (_under ?? _from.under)[key] ?? const <_Slot>[];

  Map<String, List<int>> get attemptsByOp =>
      _attemptsByOp ?? _from.attemptsByOp;

  Map<String, QueueEntry> get _ownById => _byId ??= {..._from.byId};

  Map<String, int> get forgetAt => _forgetAt ?? _from.forgetAt;

  Map<int, List<_Slot>> get forgetDays => _forgetDays ?? _from.forgetDays;

  static int _dayOf(int millis) => millis ~/ Duration.millisecondsPerDay;

  List<_Slot> _day(int day) {
    final days = _forgetDays ??= {..._from.forgetDays};
    if (_copiedDays.add(day) || !days.containsKey(day)) {
      days[day] = [...?days[day]];
    }
    return days[day]!;
  }

  void forgetBy(String id, DateTime at) {
    final millis = at.add(resendWindow).millisecondsSinceEpoch;
    if (forgetAt[id] case final known? when known <= millis) return;
    stopForgetting(id);
    (_forgetAt ??= {..._from.forgetAt})[id] = millis;
    final list = _day(_dayOf(millis));
    list.insert(_slotAt(list, millis), (millis, id));
  }

  void stopForgetting(String id) {
    final millis = forgetAt[id];
    if (millis == null) return;
    (_forgetAt ??= {..._from.forgetAt}).remove(id);
    final day = _dayOf(millis);
    final list = _day(day);
    list.remove((millis, id));
    if (list.isEmpty) _forgetDays!.remove(day);
  }

  Iterable<_Slot> checkedUnder(Target target) sync* {
    final key = target is StrategyTarget ? const _PageList() : target;
    for (final slot in underOf(key)) {
      if (byId[slot.$2] case final PendingOp entry
          when checkTargetOf(entry.op) == target) {
        yield slot;
      }
    }
  }

  Map<String, List<int>> get _ownAttempts =>
      _attemptsByOp ??= {..._from.attemptsByOp};

  Map<Object, List<_Slot>> _lists(int which) => switch (which) {
    0 => _under ??= {..._from.under},
    _ => _readers ??= {..._from.readers},
  };

  List<_Slot> _list(int which, Object key) {
    final lists = _lists(which);
    final copied = !_copied.add((which, key));
    return switch (lists[key]) {
      final list? when copied => list,
      final list => lists[key] = [...?list],
    };
  }

  void _insert(int which, Object key, _Slot slot) {
    final list = _list(which, key);
    list.insert(_slotAt(list, slot.$1), slot);
  }

  void _drop(int which, Object key, _Slot slot) {
    final list = _list(which, key);
    final at = _slotAt(list, slot.$1);
    if (at < list.length && list[at] == slot) list.removeAt(at);
    if (list.isEmpty) _lists(which).remove(key);
  }

  void add(QueueEntry entry) {
    _ownById[entry.id] = entry;
    if (entry is! PendingOp) return;
    _checkedLifetime(entry);
    final slot = (entry.place, entry.id);
    final keys = _keysOf(entry);
    for (final key in keys.under) {
      _insert(0, key, slot);
    }
    for (final key in keys.read) {
      _insert(2, key, slot);
    }
  }

  void remove(QueueEntry entry) {
    _ownById.remove(entry.id);
    stopForgetting(entry.id);
    if (entry is! PendingOp) return;
    final slot = (entry.place, entry.id);
    final keys = _keysOf(entry);
    for (final key in keys.under) {
      _drop(0, key, slot);
    }
    for (final key in keys.read) {
      _drop(2, key, slot);
    }
  }

  void replace(QueueEntry old, QueueEntry entry) {
    if (entry case PendingOp(window: WindowPassed())) stopForgetting(entry.id);
    if (old is PendingOp &&
        entry is PendingOp &&
        old.id == entry.id &&
        identical(old.op, entry.op)) {
      _ownById[entry.id] = entry;
      return;
    }
    final deadline = forgetAt[old.id];
    remove(old);
    add(entry);
    if ((entry, deadline) case (
      PendingOp(window: WindowOpen()),
      final millis?,
    ) when old.id == entry.id) {
      forgetBy(
        entry.id,
        DateTime.fromMillisecondsSinceEpoch(
          millis,
          isUtc: true,
        ).subtract(resendWindow),
      );
    }
  }

  void addAttempt(AttemptFact attempt) {
    final byOp = _ownAttempts;
    for (final opId in attempt.opIds) {
      byOp[opId] = [...?byOp[opId], attempt.number];
      if (attempt.outcome is AttemptRefusedWhole) continue;
      if (byId[opId] case PendingOp(window: WindowOpen())) {
        forgetBy(opId, attempt.at);
      }
    }
  }

  void _checkedLifetime(PendingOp entry) {
    if (entry.window is WindowOpen && expectedOf(entry.op) != null) {
      forgetBy(entry.id, entry.authoredAt);
    }
  }

  void unsent(AttemptFact refused, Map<int, AttemptFact> attempts) {
    for (final opId in refused.opIds) {
      stopForgetting(opId);
      if (byId[opId] is! PendingOp ||
          (byId[opId]! as PendingOp).window is! WindowOpen) {
        continue;
      }
      _checkedLifetime(byId[opId]! as PendingOp);
      for (final number in attemptsByOp[opId] ?? const <int>[]) {
        final attempt = attempts[number];
        if (attempt == null || attempt.outcome is AttemptRefusedWhole) continue;
        forgetBy(opId, attempt.at);
      }
    }
  }

  void removeAttempt(AttemptFact attempt) {
    final byOp = _ownAttempts;
    for (final opId in attempt.opIds) {
      final left = [
        for (final number in byOp[opId] ?? const <int>[])
          if (number != attempt.number) number,
      ];
      left.isEmpty ? byOp.remove(opId) : byOp[opId] = left;
    }
  }

  _Index build() => _Index(
    byId: _byId ?? _from.byId,
    under: _under ?? _from.under,
    readers: _readers ?? _from.readers,
    attemptsByOp: _attemptsByOp ?? _from.attemptsByOp,
    forgetAt: _forgetAt ?? _from.forgetAt,
    forgetDays: _forgetDays ?? _from.forgetDays,
  );
}

final class _Change {
  _Change();

  final touched = <String>{};
  final removed = <QueueEntry>[];
  final pages = <String>{};
  final targets = <Target>{};
  final lives = <String>{};
  bool everything = false;
}

sealed class _Counted {
  const _Counted();
}

final class _Waits extends _Counted {
  const _Waits(this.why);

  final Underway why;

  @override
  bool operator ==(Object other) => other is _Waits && other.why == why;

  @override
  int get hashCode => Object.hash(_Waits, why);
}

final class _Needs extends _Counted {
  const _Needs(this.why);

  final Attention why;

  @override
  bool operator ==(Object other) => other is _Needs && other.why == why;

  @override
  int get hashCode => Object.hash(_Needs, why);
}

final class _Derivation {
  _Derivation({
    required this.at,
    required this.states,
    required this.views,
    required this.expiry,
    required this.nextExpiry,
    required this.counted,
    required this.waiting,
    required this.attention,
  });

  final DateTime at;
  final Map<String, PendingState> states;
  final Map<String, EntryView> views;
  final Map<String, DateTime> expiry;
  final DateTime? nextExpiry;
  final Map<String, _Counted> counted;
  final Map<Underway, int> waiting;
  final Map<Attention, int> attention;
}

final class _Lineage {
  _Lineage(this.parent, this.change);

  final CloudQueue parent;
  final _Change change;
}

_Derivation _derive(CloudQueue queue, DateTime now) {
  final known = queue._derived;
  if (known != null && known.at == now) return known;
  final _Derivation derived;
  if (known != null && !now.isBefore(known.at)) {
    derived = _Deriving(queue, known, _Change(), now).run();
  } else if (queue._lineage case _Lineage(
    :final parent,
    :final change,
  ) when !change.everything && _derivable(parent, now)) {
    derived = _Deriving(queue, _derive(parent, now), change, now).run();
  } else {
    derived = _Deriving.full(queue, now).run();
  }
  queue._derived = derived;
  queue._lineage = null;
  return derived;
}

bool _derivable(CloudQueue queue, DateTime now) {
  if (queue._derived case final known? when !now.isBefore(known.at)) {
    return true;
  }
  return switch (queue._lineage) {
    _Lineage(:final parent, :final change) =>
      !change.everything && _derivable(parent, now),
    null => false,
  };
}

final class _Deriving {
  _Deriving(this.queue, _Derivation from, this.change, this.now)
    : states = {...from.states},
      views = {...from.views},
      expiry = {...from.expiry},
      nextExpiry = from.nextExpiry,
      counted = {...from.counted},
      waiting = {...from.waiting},
      attention = {...from.attention},
      full = false;

  _Deriving.full(this.queue, this.now)
    : change = _Change(),
      states = {},
      views = {},
      expiry = {},
      nextExpiry = null,
      counted = {},
      waiting = {},
      attention = {},
      full = true;

  final CloudQueue queue;
  final _Change change;
  final DateTime now;
  final Map<String, PendingState> states;
  final Map<String, EntryView> views;
  final Map<String, DateTime> expiry;
  DateTime? nextExpiry;
  final Map<String, _Counted> counted;
  final Map<Underway, int> waiting;
  final Map<Attention, int> attention;
  final bool full;
  final _dirty = SplayTreeMap<int, String>();
  final _spread = <String>{};
  var _rescan = false;

  void _setExpiry(String id, DateTime? until) {
    final was = expiry[id];
    if (was != null && was == nextExpiry && until != was) _rescan = true;
    if (until == null) {
      expiry.remove(id);
    } else {
      expiry[id] = until;
      if (nextExpiry == null || until.isBefore(nextExpiry!)) {
        nextExpiry = until;
      }
    }
  }

  _Index get index => queue._index;

  void _count(_Counted counted, int by) {
    switch (counted) {
      case _Waits(:final why):
        waiting[why] = (waiting[why] ?? 0) + by;
        if (waiting[why] == 0) waiting.remove(why);
      case _Needs(:final why):
        attention[why] = (attention[why] ?? 0) + by;
        if (attention[why] == 0) attention.remove(why);
    }
  }

  void _forget(String id) {
    states.remove(id);
    views.remove(id);
    _setExpiry(id, null);
    if (counted.remove(id) case final was?) _count(was, -1);
  }

  void _mark(String id) {
    if (index.byId[id] case final entry?) _dirty[entry.place] = id;
  }

  void _spreadFrom(PendingOp entry) {
    for (final key in _keysOf(entry).published) {
      for (final id in index.readersAfter(key, entry.place)) {
        _mark(id);
      }
    }
  }

  PendingState stateFor(String id) =>
      states[id] ??= stateOf(queue, index.byId[id]! as PendingOp);

  _Derivation run() {
    if (full) {
      for (final entry in queue.entries) {
        derivationWork.visits++;
        _dirty[entry.place] = entry.id;
      }
    } else {
      for (final entry in change.removed) {
        _forget(entry.id);
        if (entry is PendingOp) _spreadFrom(entry);
      }
      for (final id in change.touched) {
        states.remove(id);
        _spread.add(id);
        _mark(id);
      }
      for (final page in change.pages) {
        for (final id in index.ids(_OnPage(page))) {
          _mark(id);
        }
      }
      for (final target in change.targets) {
        for (final id in index.ids(target)) {
          _mark(id);
        }
      }
      for (final page in change.lives) {
        for (final id in index.ids(_PageLife(page))) {
          _mark(id);
        }
      }
      if (nextExpiry case final next? when !now.isBefore(next)) {
        _rescan = true;
        for (final MapEntry(key: id, value: at) in expiry.entries) {
          derivationWork.visits++;
          if (!now.isBefore(at)) _mark(id);
        }
      }
    }
    while (_dirty.isNotEmpty) {
      final place = _dirty.firstKey()!;
      final id = _dirty.remove(place)!;
      final entry = index.byId[id];
      if (entry == null) continue;
      _redo(entry);
    }
    if (_rescan) {
      nextExpiry = null;
      for (final at in expiry.values) {
        derivationWork.visits++;
        if (nextExpiry == null || at.isBefore(nextExpiry!)) nextExpiry = at;
      }
    }
    return _Derivation(
      at: now,
      states: states,
      views: views,
      expiry: expiry,
      nextExpiry: nextExpiry,
      counted: counted,
      waiting: waiting,
      attention: attention,
    );
  }

  void _redo(QueueEntry entry) {
    final _Counted count;
    switch (entry) {
      case RetiredOp():
        count = const _Needs(Attention.retiredFormat);
        views[entry.id] = EntryView(const NeedsUser(RetiredFormat()), const []);
      case final PendingOp entry:
        derivationWork.views++;
        states.remove(entry.id);
        final before = views[entry.id];
        final (view, until) = _viewOf(queue, entry, stateFor, now);
        views[entry.id] = view;
        _setExpiry(entry.id, until);
        if (!full && (before != view || _spread.contains(entry.id))) {
          _spreadFrom(entry);
        }
        count = _countOf(view, (id) => views[id]);
    }
    if (counted[entry.id] case final was?) _count(was, -1);
    counted[entry.id] = count;
    _count(count, 1);
  }
}

_Counted _countOf(EntryView view, EntryView? Function(String) viewOf) =>
    switch (view.state) {
      Sending() => const _Waits(Underway.sending),
      NeedsUser(:final reason) => _Needs(switch (reason) {
        RefusedByServer(refusal: RejectedByServer()) =>
          Attention.rejectedByServer,
        RefusedByServer(refusal: FailedOnServer()) => Attention.failedOnServer,
        RefusedByServer(refusal: StrategyReplacedOnServer()) =>
          Attention.rejectedByServer,
        RefusedByServer(refusal: AnsweredWithoutLife()) =>
          Attention.serverForgotAnswer,
        WindowClosed() => Attention.serverForgotAnswer,
        WrittenLongAgo() => Attention.writtenLongAgo,
        RetriesExhausted() => Attention.retriesExhausted,
        DeleteHeld() => Attention.heldPageDelete,
        Oversized() => Attention.oversized,
        ChangedUnseen() => Attention.changedUnseen,
        RowPageGone() => Attention.pageGone,
        RetiredFormat() => Attention.retiredFormat,
      }),
      Waiting() || Unanswered()
          when view.holds.any(
            (hold) =>
                hold is BehindEntry && viewOf(hold.opId)?.state is NeedsUser,
          ) =>
        const _Needs(Attention.waitingOnRefused),
      Waiting() || Unanswered()
          when view.holds.any((hold) => hold is AwaitingResult) =>
        const _Waits(Underway.awaitingResult),
      Unanswered() => const _Waits(Underway.answerUnknown),
      Waiting() => const _Waits(Underway.unsent),
    };

PendingState stateOf(CloudQueue queue, PendingOp entry) {
  if (entry.refusal case RefusedWith(:final refusal)) {
    return NeedsUser(RefusedByServer(refusal));
  }
  final attempts = [
    for (final number in queue._index.attemptsByOp[entry.id] ?? const <int>[])
      ?queue.attempts[number],
  ];
  derivationWork.visits += attempts.length;
  for (final attempt in attempts) {
    if (attempt.outcome is AttemptOpen) return Sending(attempt.number);
  }
  if (entry.window is WindowPassed) {
    return NeedsUser(
      expectedOf(entry.op) != null
          ? const WrittenLongAgo()
          : const WindowClosed(),
    );
  }
  final failed = [
    for (final attempt in attempts)
      if (attempt.outcome case AttemptFailed(:final at)) (attempt, at),
  ];
  if (failed.isEmpty) return const Waiting();
  final failures = failed.where((f) => f.$1.number > entry.retriedAfter).length;
  if (failures >= retriesBeforePause) {
    return const NeedsUser(RetriesExhausted());
  }
  return Unanswered(
    clientId: failed.first.$1.clientId,
    firstSentAt: failed.first.$1.at,
    failures: failures,
    backoff: switch (failures) {
      0 => const RetryNow(),
      _ => RetryAfter(
        retryTimeAfter(failed.last.$2, failures),
        failedAt: failed.last.$2,
      ),
    },
  );
}

DateTime? forgetsNextAt(CloudQueue queue) => queue._index.firstForgetting;

Map<String, EntryView> entryViews(CloudQueue queue, DateTime now) =>
    UnmodifiableMapView(_derive(queue, now).views);

({Map<Underway, int> waiting, Map<Attention, int> attention}) queueCounts(
  CloudQueue queue,
  DateTime now,
) {
  final derived = _derive(queue, now);
  return (
    waiting: Map.unmodifiable(derived.waiting),
    attention: Map.unmodifiable(derived.attention),
  );
}

Set<ResultSubject> owedReads(CloudQueue queue) => {
  if (isDebt(queue.shown.list)) const PageListResult(),
  for (final MapEntry(:key, :value) in queue.shown.pageReads.entries)
    if (isDebt(value)) PageResult(key),
};

int refusedReads(CloudQueue queue) => [
  queue.shown.list,
  ...queue.shown.pageReads.values,
].whereType<ReadRefused>().length;

Set<ResultSubject> resultsNeeded(CloudQueue queue, DateTime now) => {
  ...owedReads(queue),
  for (final view in _derive(queue, now).views.values)
    for (final hold in view.holds)
      if (hold case AwaitingResult(:final subject)) subject,
};

(EntryView, DateTime?) _viewOf(
  CloudQueue queue,
  PendingOp entry,
  PendingState Function(String) stateFor,
  DateTime now,
) {
  final index = queue._index;
  final op = entry.op;
  final target = targetOf(op);
  final pages = _pagesOf(entry);
  final place = entry.place;
  final state = stateFor(entry.id);
  if (state is! Waiting && state is! Unanswered) {
    return (EntryView(state, const []), null);
  }
  if (_oversized(entry)) {
    return (EntryView(const NeedsUser(Oversized()), const []), null);
  }
  final holds = <Hold>[
    if (isDebt(queue.shown.list)) const AwaitingResult(PageListResult()),
    for (final page in pages)
      if (isDebt(queue.shown.pageRead(page))) AwaitingResult(PageResult(page)),
  ];
  DateTime? until;

  void behind(String? id, Dependency why) {
    if (id != null) holds.add(BehindEntry(id, why));
  }

  behind(index.lastBefore(index.under, target, place), switch (target) {
    StrategyTarget() => Dependency.strategyChange,
    PageTarget() => Dependency.pageChange,
    SettingsTarget() || ElementTarget() || LineupTarget() => Dependency.sameRow,
  });
  if (target is PageTarget) {
    behind(
      index.lastBefore(index.under, const _Renumbering(), place),
      Dependency.pageChange,
    );
  }
  if (renumbersPages(op)) {
    behind(
      index.lastBefore(index.under, const _PagePatching(), place),
      Dependency.pageChange,
    );
  }
  final own = _ownPage(op);
  for (final page in pages) {
    if (page == own) continue;
    final lastId = index.lastBefore(index.under, _PageLife(page), place);
    if (lastId != null) {
      final last = index.byId[lastId]! as PendingOp;
      holds.add(
        BehindEntry(
          last.id,
          last.op is PageAddOp ? Dependency.pageAdd : Dependency.pageDelete,
        ),
      );
    }
  }
  if (_workPage(op) case final work?) {
    for (final id in index.allBefore(_OnPage(work), place)) {
      behind(id, Dependency.pageWork);
    }
  }
  if (state case Unanswered(
    backoff: RetryAfter(:final at, :final failedAt),
  ) when at.isAfter(now)) {
    if (failedAt.isAfter(now)) {
      until = failedAt;
    } else {
      holds.add(UntilRetryTime(at));
      until = at;
    }
  }
  final head = !holds.any((hold) => hold is BehindEntry);
  final pageGone = switch (entry.work) {
    final CheckedDelete work =>
      pageDeleteVerdict(queue.shown, work) is PageAlreadyGone,
    OpWork() => false,
  };
  if (head && state is Waiting && !pageGone) {
    switch (_judge(queue, entry, now)) {
      case _NameAt(until: final deadline?):
        if (until == null || deadline.isBefore(until)) until = deadline;
      case _NameAt():
        break;
      case _AwaitRow(:final page, until: final deadline):
        holds.add(AwaitingResult(RowResult(_rowTarget(op), page)));
        if (deadline != null && (until == null || deadline.isBefore(until))) {
          until = deadline;
        }
      case _AskUser(reason: RowPageGone()) when entry.work is CheckedDelete:
        break;
      case _AskUser(:final reason):
        return (EntryView(NeedsUser(reason), const []), null);
    }
  }
  if (entry.work case final CheckedDelete work when head) {
    final page = work.op.pagePublicId;
    switch (pageDeleteVerdict(queue.shown, work)) {
      case PageAsTheUserSawIt() || PageAlreadyGone():
        break;
      case PageResultAwaited(list: final needsList, page: final needsPage):
        if (needsList) holds.add(const AwaitingResult(PageListResult()));
        if (needsPage) holds.add(AwaitingResult(PageResult(page)));
      case PageHeld(:final cause):
        if (holds.isEmpty) {
          return (EntryView(NeedsUser(DeleteHeld(cause)), const []), null);
        }
    }
  }
  return (EntryView(state, holds), until);
}

Target _rowTarget(StrategyOp op) => switch (checkTargetOf(op)) {
  StrategyTarget() => targetOf(op),
  final target => target,
};

List<PendingOp> entriesOnRows(CloudQueue queue, Iterable<Target> targets) => [
  for (final target in targets)
    for (final id in queue._index.ids(target))
      if (queue._index.byId[id] case final PendingOp entry) entry,
];

(List<PendingOp>, Set<String>) entriesForPages(
  CloudQueue queue,
  Set<String>? pages,
) {
  final index = queue._index;
  if (pages == null) {
    final all = [
      for (final entry in queue.entries)
        if (entry is PendingOp) entry,
    ];
    return (all, {for (final entry in all) ..._pagesOf(entry)});
  }
  final wanted = {...pages};
  final picked = SplayTreeMap<int, PendingOp>();
  final frontier = [...wanted];
  void pick(String id) {
    if (index.byId[id] case final PendingOp entry
        when !picked.containsKey(entry.place)) {
      picked[entry.place] = entry;
      for (final page in _pagesOf(entry)) {
        if (wanted.add(page)) frontier.add(page);
      }
    }
  }

  for (final id in index.ids(const _PageList())) {
    pick(id);
  }
  while (frontier.isNotEmpty) {
    for (final id in index.ids(_OnPage(frontier.removeLast()))) {
      pick(id);
    }
  }
  return (picked.values.toList(), wanted);
}
