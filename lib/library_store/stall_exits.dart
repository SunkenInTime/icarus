import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus_library/icarus_library.dart';

const newEvidence = 'news about that subject: an edit on it rejected or '
    'failed (its page, or the page list for an edit of the strategy, a page '
    'or settings), a batch refused whole (the page list), the user pressing '
    'retry, a new connection, or a sign-in after a sign-out or to another '
    'account (a sign-in that only refreshes the same account on the same '
    'connection does not); each no sooner than the floor after the last read '
    'of the same subject';

const _accessAgain = 'the user pressing retry or opening the strategy in the '
    'editor (six more refusals), a sign-in, or the app starting again. Being '
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
  answerAhead(
    title: 'Our own answer is newer, by the server clock, than every result '
        'read since, and none of them shows what it wrote (the clock went '
        'back on a new connection)',
    waitsFor: 'a read of the page or page list whose server time reaches the '
        'answer\'s, or one that shows the written row at the answer\'s '
        'revision or later. Answers that leave no row to show: a page reorder, '
        'add or delete, on every page it renumbers; an edit of an item, for '
        'the page list\'s view of its page (a list shows no items); an answer '
        'with no revision (nothing to do, failed, rejected without the '
        'server\'s row), or answers on one subject of which one had none; the '
        'page an item moved off',
    calls: 'that read',
    onScreen: Face.awaitingResult,
    goesAgain: 'a read whose server time reaches the answer\'s, which the '
        'ladder issues once the server clock has caught up; a read showing '
        'the write; $newEvidence. While the editor watches the page live '
        'and the watch has given a result on this connection, the ladder '
        'makes no read of it: the next change to the page, a reconnect '
        'after which the watch gives no result in time, or the page closing '
        'lets it go again',
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
    calls: 'the page and the page list, each on its own ladder',
    onScreen: Face.unreadableWork,
    goesAgain: 'a list that shows the page, $newEvidence',
  ),
  liveNoFirstResult(
    title: 'The editor watches the page live, and the watch has given no '
        'result on this connection yet',
    waitsFor: 'the watch\'s first result',
    calls: 'nothing until the bound, then the read the queue asked for',
    onScreen: Face.awaitingResult,
    goesAgain: 'the watch\'s first result, which is taken as a read\'s '
        'would be; the page closing; or the bound passing, after which the '
        'page is read as before',
  ),
  lostRead(
    title: 'A read is lost or times out, or the read to take up a strategy '
        'is refused for the sign-in or the build on a connection that has '
        'ended',
    waitsFor: 'an answer',
    calls: 'that read',
    onScreen: Face.awaitingResult,
    goesAgain: 'an answer, $newEvidence',
  ),
  unreadableRead(
    title: 'A read comes back in rows this build cannot read, or the store '
        'will not keep it',
    waitsFor: 'an answer this build can read and keep',
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
  lookupGivenUp(
    title: 'The client does not say in time which connection it is on (the '
        'lookup throws or never answers)',
    waitsFor: 'a lookup that answers',
    calls: 'a batch whose answer came back then is sent again; a read whose '
        'result came back then is read again; a session is not opened until '
        'a lookup answers',
    onScreen: Face.needsYou,
    shownAs: 'sending while the batch is sent again; needsYou once the '
        'lost-send ladder asks the user',
    goesAgain: 'a lookup that answers, then the user asking to retry',
  ),
  offline(
    title: 'The app has no connection',
    waitsFor: 'a connection',
    calls: 'nothing',
    onScreen: Face.sending,
    goesAgain: 'the connection coming back',
  ),
  signedOut(
    title: 'No one is signed in',
    waitsFor: 'a sign-in',
    calls: 'nothing',
    onScreen: Face.sending,
    goesAgain: 'a sign-in',
  ),
  heldByHand(
    title: 'Sending is held by hand (the drive tool around a check, or at the '
        'end of its run)',
    waitsFor: 'the hold to be released',
    calls: 'nothing',
    onScreen: Face.sending,
    goesAgain: 'the release',
  ),
  lostSend(
    title: 'A batch gets no answer, or keeps being refused in a way the queue '
        'sends again (edit access the page list then confirms, or outside its '
        'window)',
    waitsFor: 'an answer that lands it',
    calls: 'the same edits',
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
  sendSpacing(
    title: 'A batch for this strategy went out moments ago',
    waitsFor: 'the send floor',
    calls: 'nothing until the floor passes',
    onScreen: Face.sending,
    goesAgain: 'the floor passing',
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
  notBeingRead(
    title: 'Nothing is queued and nothing is subscribed (send mode)',
    waitsFor: 'nothing: the store does not learn of teammates\' edits. Saved '
        'here means your changes are on the server; whether you are seeing '
        'teammates\' latest has no face in the store yet',
    calls: 'nothing',
    onScreen: null,
    goesAgain: 'an edit, or a live result of the page list or the page '
        'the editor has open',
  );

  const StallExit({
    required this.title,
    required this.waitsFor,
    required this.calls,
    required this.onScreen,
    required this.goesAgain,
    this.shownAs,
  });

  final String title;
  final String waitsFor;
  final String calls;
  final Face? onScreen;
  final String? shownAs;
  final String goesAgain;

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
      answerAhead ||
      refusedResult ||
      pageAheadOfList ||
      lostRead ||
      unreadableRead =>
        'at once, then ${ladder.join(', ')} apart, then every '
            '${span(timing.readAgainAfter)}; never twice within '
            '${span(timing.readFloor)}',
      firstRead => 'at once, one read per step',
      liveNoFirstResult => 'after ${span(timing.firstLiveResult)} without a '
          'first result, then as the read\'s own row',
      landedWork => 'after ${span(timing.quietBeforeRetiring)} without an '
          'edit, then every ${span(timing.retireAgainAfter)}',
      viewerOnly ||
      forbidden =>
        'at once, then every ${span(timing.readAgainAfter)}',
      lostSend => 'the queue\'s backoff, doubling from 0.6 s; never twice '
          'within ${span(timing.sendFloor)}',
      lookupGivenUp => 'each lookup given up after '
          '${span(timing.lookupGiveUpAfter)}; the batch again on the lost-send '
          'ladder, the read on the lost-read ladder, the session on the '
          'local-trouble ladder',
      uncheckedTooLate => 'at once',
      sendSpacing => 'one batch per ${span(timing.sendFloor)} per strategy',
      localTrouble => 'the write again after ${span(timing.firstWriteRetry)}, '
          'doubling to ${span(timing.longestWriteRetry)}; '
          '${span(timing.heldRetry)} while the store holds the strategy',
      editsSettling => '${span(timing.wait)} after the last edit, at most '
          '${span(timing.longestWait)} after the first',
      viewerOnTakeUp ||
      goneOnTakeUp ||
      signIn ||
      upgrade ||
      offline ||
      signedOut ||
      heldByHand ||
      replaced ||
      deletedOnServer ||
      refusedEdit ||
      notBeingRead =>
        'never',
    };
  }

  String bound(SenderTiming timing) => switch (this) {
        unsettledResult ||
        answerAhead ||
        lostRead =>
          '${timing.unresolvedRounds} reads, then shown as could not resolve; '
              'the ladder goes on',
        refusedResult ||
        pageAheadOfList ||
        unreadableRead =>
          '${timing.unresolvedRounds} reads, then recorded as refused '
              '(unreadable work); the ladder goes on',
        firstRead => 'one read per page',
        liveNoFirstResult => 'one wait of '
            '${timing.firstLiveResult.inSeconds} s per watch and connection',
        landedWork => '${timing.unresolvedRounds} reads that show nothing '
            'new, then shown as could not resolve and read every '
            '${timing.readAgainAfter.inMinutes} min',
        viewerOnly ||
        forbidden =>
          '${timing.accessReads} refusals while the strategy is not open in '
              'the editor, then none',
        lostSend ||
        lookupGivenUp =>
          '$retriesBeforePause failures or refusals in a row, then the user is '
              'asked',
        uncheckedTooLate => 'one send again in checked form; a refusal after '
            'that climbs the lost-send ladder',
        sendSpacing => 'the floor. It only spaces batches that are ready at '
            'once; fresh edits already wait to settle, so a user dragging '
            'makes at most a batch a second, and a batch refused or lost '
            'again climbs the lost-send ladder',
        localTrouble => 'none while the app runs',
        editsSettling => '${timing.longestWait.inSeconds} s',
        viewerOnTakeUp || goneOnTakeUp => 'one read',
        signIn ||
        upgrade ||
        offline ||
        signedOut ||
        heldByHand ||
        replaced ||
        deletedOnServer ||
        refusedEdit ||
        notBeingRead =>
          'no calls',
      };
}
