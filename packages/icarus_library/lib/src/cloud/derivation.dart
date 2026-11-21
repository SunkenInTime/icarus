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
  _Keys({required this.under, required this.acceptedUnder, required this.read});

  final List<Object> under;
  final List<Object> acceptedUnder;
  final List<Object> read;

  Iterable<Object> get published => {...under, ...acceptedUnder};
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
  PageAddOp(:final copyContentFromPagePublicId?) => copyContentFromPagePublicId,
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
      if (op case PageAddOp(:final copyContentFromPagePublicId?))
        _CopyOf(copyContentFromPagePublicId),
      for (final page in pages) _OnPage(page),
    ],
    acceptedUnder: [
      target,
      if (target is PageTarget) const StrategyTarget(),
      if (renumbersPages(op)) const _Renumbering(),
      for (final page in pages) _OnPage(page),
    ],
    read: [
      target,
      if (target is PageTarget) const _Renumbering(),
      if (renumbersPages(op)) const _PagePatching(),
      for (final page in pages)
        if (page != own) ...[_PageLife(page), _CopyOf(page)],
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

final class _CopyOf {
  const _CopyOf(this.page);

  final String page;

  @override
  bool operator ==(Object other) => other is _CopyOf && other.page == page;

  @override
  int get hashCode => Object.hash(_CopyOf, page);
}

final class _OnPage {
  const _OnPage(this.page);

  final String page;

  @override
  bool operator ==(Object other) => other is _OnPage && other.page == page;

  @override
  int get hashCode => Object.hash(_OnPage, page);
}

bool _isAccepted(PendingOp entry) => switch (entry.answer) {
  AnsweredApplied() || AnsweredNothingToDo() => true,
  NoAnswer() || AnsweredRefused() => false,
};

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
    required this.accepted,
    required this.readers,
    required this.attemptsByOp,
    required this.answered,
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

  static final empty = _Index(
    byId: const {},
    under: const {},
    accepted: const {},
    readers: const {},
    attemptsByOp: const {},
    answered: const {},
  );

  final Map<String, QueueEntry> byId;
  final Map<Object, List<_Slot>> under;
  final Map<Object, List<_Slot>> accepted;
  final Map<Object, List<_Slot>> readers;
  final Map<String, List<int>> attemptsByOp;
  final Set<String> answered;

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
  Map<Object, List<_Slot>>? _accepted;
  Map<Object, List<_Slot>>? _readers;
  Map<String, List<int>>? _attemptsByOp;
  Set<String>? _answered;
  final _copied = <(int, Object)>{};

  Map<String, QueueEntry> get byId => _byId ?? _from.byId;

  Map<String, List<int>> get attemptsByOp =>
      _attemptsByOp ?? _from.attemptsByOp;

  Set<String> get answered => _answered ?? _from.answered;

  Map<String, QueueEntry> get _ownById => _byId ??= {..._from.byId};

  Set<String> get _ownAnswered => _answered ??= {..._from.answered};

  Map<String, List<int>> get _ownAttempts =>
      _attemptsByOp ??= {..._from.attemptsByOp};

  Map<Object, List<_Slot>> _lists(int which) => switch (which) {
    0 => _under ??= {..._from.under},
    1 => _accepted ??= {..._from.accepted},
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
    final slot = (entry.place, entry.id);
    final keys = _keysOf(entry);
    for (final key in keys.under) {
      _insert(0, key, slot);
    }
    for (final key in keys.read) {
      _insert(2, key, slot);
    }
    if (_isAccepted(entry)) {
      _ownAnswered.add(entry.id);
      for (final key in keys.acceptedUnder) {
        _insert(1, key, slot);
      }
    }
  }

  void remove(QueueEntry entry) {
    _ownById.remove(entry.id);
    if (entry is! PendingOp) return;
    final slot = (entry.place, entry.id);
    final keys = _keysOf(entry);
    for (final key in keys.under) {
      _drop(0, key, slot);
    }
    for (final key in keys.read) {
      _drop(2, key, slot);
    }
    if (_isAccepted(entry)) {
      _ownAnswered.remove(entry.id);
      for (final key in keys.acceptedUnder) {
        _drop(1, key, slot);
      }
    }
  }

  void replace(QueueEntry old, QueueEntry entry) {
    if (old is PendingOp &&
        entry is PendingOp &&
        old.id == entry.id &&
        identical(old.op, entry.op)) {
      _ownById[entry.id] = entry;
      final was = _isAccepted(old);
      final now = _isAccepted(entry);
      if (was == now) return;
      final slot = (entry.place, entry.id);
      for (final key in _keysOf(entry).acceptedUnder) {
        now ? _insert(1, key, slot) : _drop(1, key, slot);
      }
      now ? _ownAnswered.add(entry.id) : _ownAnswered.remove(entry.id);
      return;
    }
    remove(old);
    add(entry);
  }

  void addAttempt(AttemptFact attempt) {
    final byOp = _ownAttempts;
    for (final opId in attempt.opIds) {
      byOp[opId] = [...?byOp[opId], attempt.number];
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
    accepted: _accepted ?? _from.accepted,
    readers: _readers ?? _from.readers,
    attemptsByOp: _attemptsByOp ?? _from.attemptsByOp,
    answered: _answered ?? _from.answered,
  );
}

final class _Change {
  _Change();

  final touched = <String>{};
  final removed = <QueueEntry>[];
  final pages = <String>{};
  final targets = <Target>{};
  bool everything = false;

  bool get isEmpty =>
      touched.isEmpty &&
      removed.isEmpty &&
      pages.isEmpty &&
      targets.isEmpty &&
      !everything;
}

sealed class _Counted {
  const _Counted();
}

final class _Waits extends _Counted {
  const _Waits(this.why);

  final Waiting why;

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

final class _Unreadable extends _Counted {
  const _Unreadable();

  @override
  bool operator ==(Object other) => other is _Unreadable;

  @override
  int get hashCode => (_Unreadable).hashCode;
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
    required this.unreadable,
  });

  final DateTime at;
  final Map<String, PendingState> states;
  final Map<String, EntryView> views;
  final Map<String, DateTime> expiry;
  final DateTime? nextExpiry;
  final Map<String, _Counted> counted;
  final Map<Waiting, int> waiting;
  final Map<Attention, int> attention;
  final int unreadable;
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
  } else if (queue._lineage case _Lineage(:final parent, :final change)
      when parent._derived != null &&
          !change.everything &&
          !now.isBefore(parent._derived!.at)) {
    derived = _Deriving(queue, parent._derived!, change, now).run();
  } else {
    derived = _Deriving.full(queue, now).run();
  }
  queue._derived = derived;
  queue._lineage = null;
  return derived;
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
      unreadable = from.unreadable,
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
      unreadable = 0,
      full = true;

  final CloudQueue queue;
  final _Change change;
  final DateTime now;
  final Map<String, PendingState> states;
  final Map<String, EntryView> views;
  final Map<String, DateTime> expiry;
  DateTime? nextExpiry;
  final Map<String, _Counted> counted;
  final Map<Waiting, int> waiting;
  final Map<Attention, int> attention;
  int unreadable;
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
      case _Unreadable():
        unreadable += by;
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
      unreadable: unreadable,
    );
  }

  void _redo(QueueEntry entry) {
    final _Counted count;
    switch (entry) {
      case UnreadableEntry():
        count = const _Unreadable();
      case RetiredOp():
        count = const _Needs(Attention.retiredFormat);
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
    switch ((view.state, view.go)) {
      (Accepted(), _) => const _Waits(Waiting.confirming),
      (Claimed(), _) => const _Waits(Waiting.sending),
      (_, NeedsFreshId()) => const _Waits(Waiting.reissue),
      (ServerRefused(refusal: RejectedByServer()), _) => const _Needs(
        Attention.rejectedByServer,
      ),
      (ServerRefused(refusal: FailedOnServer()), _) => const _Needs(
        Attention.failedOnServer,
      ),
      (_, NeedsUser(:final reason)) => _Needs(switch (reason) {
        Oversized() => Attention.oversized,
        ChangedUnseen() => Attention.changedUnseen,
        ServerForgotAnswer() => Attention.serverForgotAnswer,
        OnDeletedPage() => Attention.onDeletedPage,
        DeleteHeld() => Attention.heldPageDelete,
        IncompleteCopy() => Attention.incompletePageCopy,
      }),
      (AnswerUnknown(backoff: RetriesExhausted()), _) => const _Needs(
        Attention.retriesExhausted,
      ),
      (_, Free())
          when view.holds.any(
            (hold) =>
                hold is BehindEntry &&
                switch (viewOf(hold.opId)) {
                  EntryView(state: ServerRefused()) ||
                  EntryView(go: NeedsUser()) => true,
                  _ => false,
                },
          ) =>
        const _Needs(Attention.waitingOnRefused),
      (_, Free()) when view.holds.any((hold) => hold is AwaitingBase) =>
        const _Waits(Waiting.awaitingBase),
      (AnswerUnknown(), Free()) => const _Waits(Waiting.answerUnknown),
      (NeverSent(), Free()) => const _Waits(Waiting.unsent),
    };

PendingState stateOf(CloudQueue queue, PendingOp entry) {
  switch (entry.answer) {
    case AnsweredApplied(:final revision):
      return Accepted(revision);
    case AnsweredRefused(:final refusal):
      return ServerRefused(refusal);
    case AnsweredNothingToDo():
      return const Accepted(0);
    case NoAnswer():
      break;
  }
  final attempts = [
    for (final number in queue._index.attemptsByOp[entry.id] ?? const <int>[])
      ?queue.attempts[number],
  ];
  derivationWork.visits += attempts.length;
  for (final attempt in attempts) {
    if (attempt.outcome is AttemptOpen) return Claimed(attempt.number);
  }
  final failed = [
    for (final attempt in attempts)
      if (attempt.outcome case AttemptFailed(:final at)) (attempt, at),
  ];
  if (failed.isEmpty) return const NeverSent();
  final failures = failed.where((f) => f.$1.number > entry.retriedAfter).length;
  return AnswerUnknown(
    clientId: failed.first.$1.clientId,
    firstSentAt: failed.first.$1.at,
    failures: failures,
    backoff: switch (failures) {
      0 => const RetryNow(),
      _ when failures >= retriesBeforePause => const RetriesExhausted(),
      _ => RetryAfter(retryTimeAfter(failed.last.$2, failures)),
    },
  );
}

bool _open(PendingState state) => switch (state) {
  Accepted() => false,
  NeverSent() || Claimed() || AnswerUnknown() || ServerRefused() => true,
};

Map<String, EntryView> entryViews(CloudQueue queue, DateTime now) =>
    UnmodifiableMapView(_derive(queue, now).views);

({Map<Waiting, int> waiting, Map<Attention, int> attention, int unreadable})
queueCounts(CloudQueue queue, DateTime now) {
  final derived = _derive(queue, now);
  return (
    waiting: derived.waiting,
    attention: derived.attention,
    unreadable: derived.unreadable,
  );
}

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
  final holds = <Hold>[];
  Go go = const Free();
  DateTime? until;
  void behind(String? id, Dependency why) {
    if (id != null && _open(stateFor(id))) holds.add(BehindEntry(id, why));
  }

  if (state case NeverSent() || AnswerUnknown()) {
    behind(index.lastBefore(index.under, target, place), switch (target) {
      StrategyTarget() => Dependency.strategyChange,
      PageTarget() => Dependency.pageChange,
      SettingsTarget() ||
      ElementTarget() ||
      LineupTarget() => Dependency.sameRow,
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
      behind(
        index.lastBefore(index.under, _CopyOf(page), place),
        Dependency.pageCopy,
      );
      final lastId = index.lastBefore(index.under, _PageLife(page), place);
      final last = lastId == null ? null : index.byId[lastId]! as PendingOp;
      if (last != null && _open(stateFor(last.id))) {
        holds.add(
          BehindEntry(
            last.id,
            last.op is PageAddOp ? Dependency.pageAdd : Dependency.pageDelete,
          ),
        );
        continue;
      }
      final since = last == null ? 0 : _answeredAfterRead(last);
      if (queue.base.pageGoneAfter(page, since)) {
        go = NeedsUser(OnDeletedPage(page));
      } else if (switch (last?.op) {
        PageDeleteOp() => !queue.base.pageLiveAfter(page, since),
        PageAddOp(copyContentFromPagePublicId: _?) => true,
        _ => false,
      }) {
        holds.add(AwaitingBase(PageTarget(page)));
      }
    }
    if (_workPage(op) case final work?) {
      for (final id in index.allBefore(_OnPage(work), place)) {
        behind(id, Dependency.pageWork);
      }
    }
    if (state case AnswerUnknown(
      backoff: RetryAfter(:final at),
    ) when at.isAfter(now)) {
      holds.add(UntilRetryTime(at));
      until = at;
    }
    if (state case AnswerUnknown(:final firstSentAt)) {
      final forgottenAt = firstSentAt.add(serverRemembersAnswersFor);
      if (forgottenAt.isAfter(now) &&
          (until == null || forgottenAt.isBefore(until))) {
        until = forgottenAt;
      }
    }
    if (entry.work case CheckedDelete(
      :final op,
    ) when !queue.session.pagesReadThisSession.contains(op.pagePublicId)) {
      holds.add(AwaitingPageRead(op.pagePublicId));
    }
    if (_oversized(entry)) go = const NeedsUser(Oversized());
    if (entry.work case ImportedIncompleteCopy(:final op)) {
      go = NeedsUser(IncompleteCopy(op.pagePublicId));
    }
    if (holds.isEmpty && go is Free) {
      go = _checked(
        queue,
        entry,
        state,
        now,
        index.lastBefore(index.accepted, target, place) ??
            (target is PageTarget
                ? index.lastBefore(index.accepted, const _Renumbering(), place)
                : null),
        (page) =>
            index.lastBefore(index.accepted, _OnPage(page), place) != null,
        holds,
      );
    }
  } else if ((state, entry.answer)
      case (
        ServerRefused(
          refusal: FailedOnServer(
            code: KnownFailure(code: FailureCode.pageDeleted),
          ),
        ),
        AnsweredRefused(:final afterRead),
      )
      when pages.isNotEmpty &&
          pages.every((page) => queue.base.pageLiveAfter(page, afterRead))) {
    go = const NeedsFreshId(PageLiveAgain());
  }
  return (EntryView(state, go, holds), until);
}
