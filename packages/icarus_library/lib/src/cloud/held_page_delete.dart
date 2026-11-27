import 'op_facts.dart';
import 'pending.dart';
import 'shown.dart';

sealed class PageDeleteVerdict {
  const PageDeleteVerdict();
}

final class PageAsTheUserSawIt extends PageDeleteVerdict {
  const PageAsTheUserSawIt();
}

final class PageResultAwaited extends PageDeleteVerdict {
  const PageResultAwaited({required this.list, required this.page});

  final bool list;
  final bool page;
}

final class PageAlreadyGone extends PageDeleteVerdict {
  const PageAlreadyGone();
}

final class PageHeld extends PageDeleteVerdict {
  const PageHeld(this.cause);

  final HeldDeleteCause cause;
}

enum HeldDeleteCause { pageChanged, contentNeverRead }

PageDeleteVerdict pageDeleteVerdict(Shown shown, CheckedDelete work) {
  final page = work.op.pagePublicId;
  final listFresh = shown.listCurrentFor(page);
  final pageFresh = shown.pageResultCurrent(page);
  final listed = shown.pages.containsKey(page);
  if (listFresh && pageFresh && listed == shown.goneByResult(page)) {
    return const PageResultAwaited(list: true, page: true);
  }
  if (!listFresh || (!pageFresh && listed)) {
    return PageResultAwaited(
      list: !listFresh,
      page: !pageFresh && (!listFresh || listed),
    );
  }
  if (!listed) return const PageAlreadyGone();
  final seen = work.seen;
  final digests = switch (seen.content) {
    ContentSeen(:final digests) => digests,
    ContentNeverRead() => null,
  };
  if (digests == null) return const PageHeld(HeldDeleteCause.contentNeverRead);
  final pageRow = shown.pages[page];
  final content = shown.content[page];
  if (pageRow == null || content == null) {
    return const PageHeld(HeldDeleteCause.pageChanged);
  }
  final current = {
    if (shown.settings[page] case final settings?)
      const SeenSettings(): settings.digest,
    for (final MapEntry(:key, :value) in content.entries)
      if (!_shownElsewhere(shown, key, page)) key: value,
  };
  return sameMap(current, digests) && pageRow.digest == seen.pageDigest
      ? const PageAsTheUserSawIt()
      : const PageHeld(HeldDeleteCause.pageChanged);
}

bool _shownElsewhere(Shown shown, SeenPart part, String page) {
  final target = switch (part) {
    SeenElement(:final id) => ElementTarget(id) as Target,
    SeenLineupGroup(:final id) => LineupTarget(id),
    SeenSettings() => null,
  };
  if (target == null) return false;
  return switch (shown.rows[target]?.page) {
    final at? => at != page,
    null => false,
  };
}
