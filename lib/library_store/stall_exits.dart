import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus_library/icarus_library.dart';

const newEvidence = 'a server answer about the strategy that is not only '
    'applied edits, the user pressing retry, or a new connection';

enum StallExit {
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
    onScreen: Face.awaitingResult,
    goesAgain: 'an answer, $newEvidence',
  ),
  viewerOnly(
    title: 'Edit access lost, and the page list says this account can view',
    waitsFor: 'a page list saying this account edits',
    calls: 'the page list',
    onScreen: Face.editAccessLost,
    goesAgain: 'the user pressing retry (six more reads), a sign-in, the app '
        'starting again, or the user discarding. Being shared the strategy '
        'again shows only on a read, so it needs one of these',
  ),
  forbidden(
    title: 'Edit access lost, and the page list is refused as FORBIDDEN '
        '(a teammate not shared a replacement)',
    waitsFor: 'a page list this account may read',
    calls: 'the page list',
    onScreen: Face.editAccessLost,
    goesAgain: 'the user pressing retry (six more reads), a sign-in, the app '
        'starting again, or the user discarding. Being shared the strategy '
        'again shows only on a read, so it needs one of these',
  ),
  signIn(
    title: 'The server refuses the sign-in (UNAUTHENTICATED or '
        'ACCOUNT_MISMATCH)',
    waitsFor: 'the sign-in to change',
    calls: 'nothing',
    onScreen: Face.sending,
    goesAgain: 'a sign-in',
  ),
  upgrade(
    title: 'The server asks for a newer build',
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
    goesAgain: 'the user discarding or keeping a copy',
  ),
  refusedEdit(
    title: 'The server refused an edit',
    waitsFor: 'the user',
    calls: 'nothing',
    onScreen: Face.needsYou,
    goesAgain: 'the user retrying, using the cloud version or discarding',
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
  });

  final String title;
  final String waitsFor;
  final String calls;
  final Face? onScreen;
  final String goesAgain;

  String schedule(SenderTiming timing) {
    String span(Duration d) => d.inMinutes >= 1
        ? '${d.inMinutes} min'
        : '${d.inMilliseconds / 1000} s'.replaceAll('.0 s', ' s');
    return switch (this) {
      unsettledResult ||
      refusedResult ||
      pageAheadOfList ||
      lostRead =>
        'at once, then '
            '${[
          for (var n = 1; n < timing.unresolvedRounds; n++)
            span(timing.settleAfter(n)),
        ].join(', ')} apart, then every '
            '${span(timing.settleAfter(timing.unresolvedRounds))}',
      viewerOnly ||
      forbidden =>
        'at once, then every ${span(timing.readAgainAfter)}',
      lostSend => 'the queue\'s backoff, doubling from 0.6 s',
      signIn ||
      upgrade ||
      replaced ||
      deletedOnServer ||
      refusedEdit ||
      notBeingRead =>
        'never',
    };
  }

  String bound(SenderTiming timing) => switch (this) {
        unsettledResult => '${timing.unresolvedRounds} reads, then shown as '
            'could not resolve and read every '
            '${timing.readAgainAfter.inMinutes} min',
        refusedResult ||
        pageAheadOfList =>
          '${timing.unresolvedRounds} reads, then recorded as refused and read '
              'every ${timing.readAgainAfter.inMinutes} min',
        lostRead => '${timing.unresolvedRounds} reads, then read every '
            '${timing.readAgainAfter.inMinutes} min',
        viewerOnly ||
        forbidden =>
          '${timing.accessReads} reads, then none until the user retries, a '
              'sign-in, or the app starts again',
        lostSend => '$retriesBeforePause failures, then the user is asked',
        signIn ||
        upgrade ||
        replaced ||
        deletedOnServer ||
        refusedEdit =>
          'no calls',
        notBeingRead => 'no calls',
      };
}
