import 'pending.dart';
import 'shown.dart';

sealed class PageDeleteVerdict {
  const PageDeleteVerdict();
}

final class PageAsTheUserSawIt extends PageDeleteVerdict {
  const PageAsTheUserSawIt();
}

final class PageResultAwaited extends PageDeleteVerdict {
  const PageResultAwaited();
}

final class PageAlreadyGone extends PageDeleteVerdict {
  const PageAlreadyGone();
}

final class PageHeld extends PageDeleteVerdict {
  const PageHeld(this.cause);

  final HeldDeleteCause cause;
}

enum HeldDeleteCause { pageChanged, contentNeverRead }

PageDeleteVerdict pageDeleteVerdict(
  Shown shown,
  CheckedDelete work, {
  required bool ownWorkLandedOnPage,
  Map<SeenPart, String>? known,
  String? knownPageDigest,
}) {
  final page = work.op.pagePublicId;
  final seen = work.seen;
  final digests = switch (seen.content) {
    ContentSeen(:final digests) => digests,
    ContentNeverRead() => null,
  };
  final pageRow = shown.pages[page];
  if ((pageRow == null && shown.headerThisSession) ||
      shown.goneThisSession.contains(page)) {
    return const PageAlreadyGone();
  }
  if (digests == null) return const PageHeld(HeldDeleteCause.contentNeverRead);
  if (ownWorkLandedOnPage) return const PageResultAwaited();
  final content = shown.pagesThisSession.contains(page)
      ? (known ?? shown.content[page])
      : null;
  if (content == null || pageRow == null) return const PageResultAwaited();
  final current = {
    if (shown.settings[page] case final settings?)
      const SeenSettings(): settings.digest,
    ...content,
  };
  final same =
      sameMap(current, digests) &&
      (knownPageDigest ?? pageRow.digest) == seen.pageDigest;
  return same
      ? const PageAsTheUserSawIt()
      : const PageHeld(HeldDeleteCause.pageChanged);
}
