import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus_library/icarus_library.dart';

const newEvidence = 'a server answer about the strategy that is not only '
    'applied edits, the user pressing retry, or a new connection, each no '
    'sooner than the floor after the last read of the same subject';

const _accessAgain = 'the user pressing retry or opening the strategy in the '
    'editor (six more reads), a sign-in, or the app starting again. Being '
    'shared the strategy again shows only on a read, so it needs one of '
    'these. While the strategy is open in the editor the check never stops';

enum StallExit {
  firstRead(
    title: 'A strategy is read for the first time, or again after it was '
        'replaced',
    waitsFor: 'every page the page list shows',
    calls: 'the page list, then each page, one per step',
    onScreen: Face.awaitingResult,
    goesAgain: 'each page that is read; a page that will not read climbs the '
        'ladder as a lost read',
  ),
  unsettledResult(
    title: 'A result the queue asked for does not settle it',
    waitsFor: 'the page or page list a held edit or a debt names',
    calls: 'that read',
    onScreen: Face.awaitingResult,
    goesAgain: 'a read that settles it, $newEvidence',
  ),
  refusedResult(
    title: 'The queue does not take a result (a page list of an earlier life '
        'than the record holds)',
    waitsFor: 'a list the queue takes',
    calls: 'the page list',
    onScreen: Face.unreadableWork,
    goesAgain: 'a list the queue takes, $newEvidence',
  ),
  pageAheadOfList(
    title: 'A page is newer than its page list',
    waitsFor: 'a page list showing the page in that life',
    calls: 'the page, then the page list, together each round',
    onScreen: Face.unreadableWork,
    goesAgain: 'a list that shows the page, $newEvidence',
  ),
  lostRead(
    title: 'A read is lost or comes back unreadable',
    waitsFor: 'an answer this build can read',
    calls: 'that read',
    onScreen: Face.unreadableWork,
    goesAgain: 'an answer, $newEvidence',
  ),
  landedWork(
    title: 'Landed work waits for a read that shows it',
    waitsFor: 'a read of the page or page list that holds it',
    calls: 'that read',
    onScreen: null,
    goesAgain: 'a read that shows it, or an edit (which starts the quiet '
        'period again)',
  ),
  viewerOnly(
    title: 'Edit access lost, and the page list says this account can view',
    waitsFor: 'a page list saying this account edits',
    calls: 'the page list',
    onScreen: Face.editAccessLost,
    goesAgain: _accessAgain,
  ),
  forbidden(
    title: 'Edit access lost, and the page list is refused as FORBIDDEN '
        '(a teammate not shared a replacement)',
    waitsFor: 'a page list this account may read',
    calls: 'the page list',
    onScreen: Face.editAccessLost,
    goesAgain: _accessAgain,
  ),
  viewerOnTakeUp(
    title: 'Taking up a strategy this account can only view',
    waitsFor: 'nothing: it is not added to the library',
    calls: 'the page list, once',
    onScreen: null,
    shownAs: 'nothing: not in the library',
    goesAgain: 'the user opening it again',
  ),
  goneOnTakeUp(
    title: 'Taking up a strategy the server no longer has',
    waitsFor: 'nothing: it is not added to the library',
    calls: 'the page list, once',
    onScreen: null,
    shownAs: 'nothing: not in the library',
    goesAgain: 'the user opening it again',
  ),
  signIn(
    title: 'The server refuses the sign-in (UNAUTHENTICATED or '
        'ACCOUNT_MISMATCH), on a send or on a read',
    waitsFor: 'the sign-in to change',
    calls: 'nothing',
    onScreen: Face.sending,
    shownAs: 'what the waiting work showed before the refusal: sending for '
        'an unsent edit; in the read test, needsYou for a refused edit '
        'waiting for its page',
    goesAgain: 'a sign-in',
  ),
  upgrade(
    title: 'The server asks for a newer build, on a send or on a read',
    waitsFor: 'a newer build',
    calls: 'nothing',
    onScreen: Face.upgradeRequired,
    goesAgain: 'the app starting again on a newer build',
  ),
  lostSend(
    title: 'A batch gets no answer',
    waitsFor: 'an answer to the same batch',
    calls: 'the same batch',
    onScreen: Face.needsYou,
    goesAgain: 'the user asking to retry',
  ),
  uncheckedTooLate(
    title: 'An unchecked batch reaches the server outside its window',
    waitsFor: 'the same edits, sent again with their checks',
    calls: 'the same edits, checked',
    onScreen: null,
    goesAgain: 'at once',
  ),
  replaced(
    title: 'The strategy was replaced',
    waitsFor: 'the user to discard what was set aside',
    calls: 'nothing',
    onScreen: Face.strategyReplaced,
    goesAgain: 'the user discarding',
  ),
  deletedOnServer(
    title: 'The strategy was deleted on the server',
    waitsFor: 'the user',
    calls: 'nothing',
    onScreen: Face.deletedOnServer,
    goesAgain: 'the user discarding',
  ),
  refusedEdit(
    title: 'The server refused an edit',
    waitsFor: 'the user',
    calls: 'nothing',
    onScreen: Face.needsYou,
    goesAgain: 'the user retrying, using the cloud version or discarding',
  ),
  localTrouble(
    title: 'This device cannot write the queue (the store, the session or '
        'the claim)',
    waitsFor: 'a write that succeeds',
    calls: 'nothing: a result already read is kept and written again, not '
        'read again',
    onScreen: Face.needsYou,
    shownAs: 'what the waiting work showed (in the test, needsYou: an edit '
        'the server refused, waiting for its page result)',
    goesAgain: 'a write that succeeds',
  ),
  editsSettling(
    title: 'The user is still editing',
    waitsFor: 'a pause in the edits',
    calls: 'nothing',
    onScreen: Face.sending,
    goesAgain: 'the pause',
  ),
  liveResultsBehind(
    title: 'Shadow mode only: a live result from before a send\'s commit '
        'arrives after the send is answered',
    waitsFor: 'a live result that includes the commit',
    calls: 'nothing: the editor\'s live queries',
    onScreen: null,
    shownAs: 'not measured here. A known state of shadow mode until the '
        'vendored Rust client waits for a send\'s transition before it '
        'resolves the send, as the JavaScript client does; that fix comes '
        'next. Whether the editor then shows the edit undone and redone is '
        'measured in that fix',
    goesAgain: 'the next live result',
    inSenderWorld: false,
  ),
  notBeingRead(
    title: 'Nothing is queued and nothing is subscribed (send mode)',
    waitsFor: 'nothing: the store does not learn of teammates\' edits. Saved '
        'here means your changes are on the server; whether you are seeing '
        'teammates\' latest has no face in the store yet',
    calls: 'nothing',
    onScreen: null,
    goesAgain: 'an edit, or the editor\'s live results once the store is '
        'their source (decided, not built)',
  );

  const StallExit({
    required this.title,
    required this.waitsFor,
    required this.calls,
    required this.onScreen,
    required this.goesAgain,
    this.shownAs,
    this.inSenderWorld = true,
  });

  final String title;
  final String waitsFor;
  final String calls;
  final Face? onScreen;
  final String? shownAs;
  final String goesAgain;
  final bool inSenderWorld;

  String get shown => shownAs ?? onScreen?.name ?? 'saved';

  String schedule(SenderTiming timing) {
    String span(Duration d) => d.inMinutes >= 1 && d.inSeconds % 60 == 0
        ? '${d.inMinutes} min'
        : '${d.inMilliseconds / 1000} s'.replaceAll('.0 s', ' s');
    final ladder = [
      for (var n = 1; timing.settleAfter(n) < timing.readAgainAfter; n++)
        span(timing.settleAfter(n)),
    ];
    return switch (this) {
      unsettledResult ||
      refusedResult ||
      pageAheadOfList ||
      lostRead =>
        'at once, then ${ladder.join(', ')} apart, then every '
            '${span(timing.readAgainAfter)}; never twice within '
            '${span(timing.readFloor)}',
      firstRead => 'at once, one read per step',
      landedWork => 'after ${span(timing.quietBeforeRetiring)} without an '
          'edit, then every ${span(timing.retireAgainAfter)}',
      viewerOnly ||
      forbidden =>
        'at once, then every ${span(timing.readAgainAfter)}',
      lostSend => 'the queue\'s backoff, doubling from 0.6 s',
      uncheckedTooLate => 'at once',
      localTrouble => 'the write again after ${span(timing.firstWriteRetry)}, '
          'doubling to ${span(timing.longestWriteRetry)}; '
          '${span(timing.heldRetry)} while the store holds the strategy',
      editsSettling => '${span(timing.wait)} after the last edit, at most '
          '${span(timing.longestWait)} after the first',
      viewerOnTakeUp ||
      goneOnTakeUp ||
      signIn ||
      upgrade ||
      replaced ||
      deletedOnServer ||
      refusedEdit ||
      liveResultsBehind ||
      notBeingRead =>
        'never',
    };
  }

  String bound(SenderTiming timing) => switch (this) {
        unsettledResult => '${timing.unresolvedRounds} reads, then shown as '
            'could not resolve; the ladder goes on',
        refusedResult ||
        pageAheadOfList ||
        lostRead =>
          '${timing.unresolvedRounds} reads, then recorded as refused '
              '(unreadable work); the ladder goes on',
        firstRead => 'one read per page',
        landedWork => '${timing.unresolvedRounds} reads that show nothing '
            'new, then shown as could not resolve and read every '
            '${timing.readAgainAfter.inMinutes} min',
        viewerOnly ||
        forbidden =>
          '${timing.accessReads} reads while the strategy is not open in the '
              'editor, then none',
        lostSend => '$retriesBeforePause failures, then the user is asked',
        uncheckedTooLate => 'one send again in checked form. A server that '
            'refuses that too gets it again at once, without end (#779)',
        localTrouble => 'none while the app runs',
        editsSettling => '${timing.longestWait.inSeconds} s',
        viewerOnTakeUp || goneOnTakeUp => 'one read',
        signIn ||
        upgrade ||
        replaced ||
        deletedOnServer ||
        refusedEdit ||
        liveResultsBehind ||
        notBeingRead =>
          'no calls',
      };
}
