import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('a refresh after a failed page selection resumes its live read',
      () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');

    // A teammate deletes page a; reading b, where the editor moves, fails.
    repository.failPageReads = true;
    repository.shells.add(_shell(['b']));
    await _settle();
    expect(remote.activePagePublicId, 'b');
    expect(repository.watchedPages, isNot(contains('b')));

    repository.failPageReads = false;
    // Two refreshes at once start one live read, not two.
    await Future.wait([remote.refresh(), remote.refresh()]);
    expect(repository.watchedPages.where((id) => id == 'b'), hasLength(1));
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .revision,
      1,
    );

    // A teammate's later edit to b reaches the editor.
    repository.pageStreams['b']!.add(_page('b', revision: 2));
    await _settle();
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .revision,
      2,
    );
  });

  test('a restored page is read fresh with the shell and watched again',
      () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');
    // A teammate deletes page a; the editor's live read moves to b.
    repository.shells.add(_shell(['b']));
    await _settle();
    expect(remote.activePagePublicId, 'b');

    // Restored on the server; the shell watched has not caught up yet.
    await remote.showRestoredPage('a');

    final snapshot = container.read(remoteEditorSnapshotProvider).valueOrNull;
    expect(snapshot?.activePage?.page.publicId, 'a');
    expect(snapshot?.pages.map((page) => page.publicId), ['a', 'b']);
    expect(repository.watchedPages.last, 'a');
    repository.pageStreams['a']!.add(_page('a', revision: 2));
    await _settle();
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .revision,
      2,
    );
  });

  test('a read from before a restore finishing late changes nothing', () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');
    repository.shells.add(_shell(['b'], revision: 2));
    await _settle();

    // Restoring bumped the strategy's revision.
    repository.shellRevision = 3;
    // A refresh starts while the page is still deleted...
    final gate = Completer<void>();
    repository.staleShellGate = gate;
    final stale = remote.refresh();
    // ...and the page is restored and shown before it answers.
    await remote.showRestoredPage('a');
    gate.complete();
    await stale;
    // The watched shell's last push, from before the restore, arrives late.
    repository.shells.add(_shell(['b'], revision: 2));
    await _settle();

    final snapshot = container.read(remoteEditorSnapshotProvider).valueOrNull;
    expect(snapshot?.activePage?.page.publicId, 'a');
    expect(snapshot?.pages.map((page) => page.publicId), ['a', 'b']);
    expect(remote.activePagePublicId, 'a');
  });

  test('a refresh never replaces a newer shell the live read brought',
      () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'b');

    // A refresh reads the shell from while a was deleted, then waits on b.
    repository.shellRevision = 2;
    repository.failPageReads = false;
    final gate = Completer<void>();
    repository.pageReadGate = gate;
    final refresh = remote.refresh();
    await _settle();
    // Meanwhile a teammate restores a; the live read brings it.
    repository.shells.add(_shell(['a', 'b'], revision: 3));
    await _settle();
    gate.complete();
    await refresh;

    final snapshot = container.read(remoteEditorSnapshotProvider).valueOrNull;
    expect(snapshot?.header.revision, 3);
    expect(snapshot?.pages.map((page) => page.publicId), ['a', 'b']);
  });

  test('a page read a restore overtook failing late changes nothing', () async {
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);
    await remote.openStrategy('strategy', activePagePublicId: 'a');

    // A is deleted: the editor starts reading b, slowly, and it will fail.
    final gate = Completer<void>();
    repository.pageReadGate = gate;
    repository.failNextRead.add('b');
    final selectB = remote.setActivePage('b');
    await _settle();
    // A is restored and shown before b's read answers.
    await remote.showRestoredPage('a');
    gate.complete();
    await selectB;

    final state = container.read(remoteEditorSnapshotProvider);
    expect(state.hasError, isFalse);
    expect(state.valueOrNull?.activePage?.page.publicId, 'a');
    repository.pageStreams['a']!.add(_page('a', revision: 2));
    await _settle();
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .revision,
      2,
    );
  });

  test('a signed-out reader on a share link reads through the link', () async {
    final repository = _Repository();
    final auth = _SignedOutAuthProvider();
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(() => auth),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    container.read(shareLinkViewProvider.notifier).state =
        (strategyPublicId: 'strategy', token: 'ICR-LINK');
    final remote = container.read(remoteEditorSnapshotProvider.notifier);
    await container.read(remoteEditorSnapshotProvider.future);

    await remote.openStrategy('strategy');
    expect(repository.readTokens, isNotEmpty);
    expect(repository.readTokens, everyElement('ICR-LINK'));

    // A refusal is the link's, not a broken session: there is no session,
    // so no auth incident opens, and the editor sees the error itself.
    repository.shellError = const ConvexFunctionException(
      code: ConvexErrorCode.unauthenticated,
      rawCode: 'UNAUTHENTICATED',
      message: 'Unauthenticated',
    );
    await remote.refresh();
    expect(auth.unauthenticatedReports, 0);
    expect(container.read(remoteEditorSnapshotProvider).hasError, isTrue);

    repository.shellError = const ConvexFunctionException(
      code: ConvexErrorCode.shareLinkRevoked,
      rawCode: 'SHARE_LINK_REVOKED',
      message: 'Share link revoked',
    );
    await remote.refresh();
    expect(auth.unauthenticatedReports, 0);
    expect(
      isShareLinkRevokedError(
        container.read(remoteEditorSnapshotProvider).error!,
      ),
      isTrue,
    );

    // A strategy opened any other way reads with the reader's own access.
    repository.shellError = null;
    repository.readTokens.clear();
    await remote.openStrategy('another-strategy');
    expect(repository.readTokens, everyElement(isNull));
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

RemotePage _remotePage(String id, {int revision = 1}) => RemotePage(
      publicId: id,
      strategyPublicId: 'strategy',
      name: id,
      sortIndex: 0,
      isAttack: true,
      revision: revision,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

RemoteStrategyShell _shell(List<String> pageIds, {int revision = 1}) =>
    RemoteStrategyShell(
      header: RemoteStrategyHeader(
        publicId: 'strategy',
        name: 'Strategy',
        mapData: 'ascent',
        revision: revision,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        role: 'owner',
      ),
      pages: [for (final id in pageIds) _remotePage(id)],
    );

RemotePageSnapshot _page(String id, {int revision = 1}) => RemotePageSnapshot(
      page: _remotePage(id, revision: revision),
      content: RemotePageContent(
        revision: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
      elements: const [],
      lineups: const [],
      assetsById: const {},
    );

class _Repository extends ConvexStrategyRepository {
  _Repository() : super(IcarusConvexApi(_UnusedTransport()));

  final shells = StreamController<RemoteStrategyShell>.broadcast();
  final pageStreams = <String, StreamController<RemotePageSnapshot>>{};
  final watchedPages = <String>[];

  /// The share token each read carried, in order.
  final readTokens = <String?>[];
  bool failPageReads = false;
  Object? shellError;

  /// While set, a shell read answers from before page a was restored, once
  /// the gate opens.
  Completer<void>? staleShellGate;

  /// The revision of the shell reads answer.
  int shellRevision = 1;

  /// While set, the next page read waits for it, then answers as usual.
  Completer<void>? pageReadGate;

  /// Pages whose next read fails.
  final failNextRead = <String>{};

  @override
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    readTokens.add(shareToken);
    if (shellError case final error?) throw error;
    final gate = staleShellGate;
    if (gate != null) {
      staleShellGate = null;
      await gate.future;
      return _shell(['b'], revision: 2);
    }
    return _shell(failPageReads ? ['b'] : ['a', 'b'], revision: shellRevision);
  }

  @override
  Stream<RemoteStrategyShell> watchShell(
    String strategyPublicId, {
    String? shareToken,
  }) {
    readTokens.add(shareToken);
    return shells.stream;
  }

  @override
  Future<RemotePageSnapshot> fetchPageSnapshot({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) async {
    readTokens.add(shareToken);
    final gate = pageReadGate;
    if (gate != null) {
      pageReadGate = null;
      await gate.future;
    }
    if (failPageReads || failNextRead.remove(pagePublicId)) {
      throw StateError('offline');
    }
    return _page(pagePublicId);
  }

  @override
  Stream<RemotePageSnapshot> watchPageSnapshot({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) {
    readTokens.add(shareToken);
    watchedPages.add(pagePublicId);
    return (pageStreams[pagePublicId] ??=
            StreamController<RemotePageSnapshot>.broadcast())
        .stream;
  }
}

class _ReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: 'account-a',
          appMetadata: const <String, dynamic>{},
          userMetadata: const <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _SignedOutAuthProvider extends AuthProvider {
  int unauthenticatedReports = 0;

  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );

  @override
  Future<void> reportConvexUnauthenticated({
    required String source,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    unauthenticatedReports += 1;
  }
}

class _IdleOpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'strategy',
        clientId: 'client',
        durableLoaded: true,
      );

  @override
  void setActiveStrategy(
    String? strategyPublicId, {
    required String? accountId,
  }) {}
}

class _IdleMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);
}

class _UnusedTransport implements ConvexTransport {
  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      throw UnimplementedError();
}
