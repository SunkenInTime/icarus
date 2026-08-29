import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';

void main() {
  test('failed cloud folder deletion preserves the selected folder', () async {
    final repository = _DeleteFolderRepository(shouldFail: true);
    final container = _createContainer(repository);
    addTearDown(container.dispose);

    final notifier = container.read(folderProvider.notifier);
    notifier.updateID('folder-1');

    notifier.deleteFolder(
      'folder-1',
      workspace: LibraryWorkspace.cloud,
    );
    await repository.deleteAttempted;
    await Future<void>.delayed(Duration.zero);

    expect(container.read(folderProvider), 'folder-1');
  });

  test('successful cloud folder deletion clears the selected folder', () async {
    final repository = _DeleteFolderRepository();
    final container = _createContainer(repository);
    addTearDown(container.dispose);

    final notifier = container.read(folderProvider.notifier);
    notifier.updateID('folder-1');

    notifier.deleteFolder(
      'folder-1',
      workspace: LibraryWorkspace.cloud,
    );
    await repository.deleteAttempted;
    await Future<void>.delayed(Duration.zero);

    expect(container.read(folderProvider), isNull);
  });
}

ProviderContainer _createContainer(ConvexStrategyRepository repository) {
  return ProviderContainer(
    overrides: [
      libraryWorkspaceProvider.overrideWith(_CloudWorkspaceNotifier.new),
      convexStrategyRepositoryProvider.overrideWithValue(repository),
    ],
  );
}

class _CloudWorkspaceNotifier extends LibraryWorkspaceNotifier {
  @override
  LibraryWorkspace build() => LibraryWorkspace.cloud;
}

class _DeleteFolderRepository extends ConvexStrategyRepository {
  _DeleteFolderRepository({this.shouldFail = false})
      : super(IcarusConvexApi(_UnusedTransport()));

  final bool shouldFail;
  final _deleteAttempted = Completer<void>();

  Future<void> get deleteAttempted => _deleteAttempted.future;

  @override
  Future<void> deleteFolder(String folderPublicId) async {
    _deleteAttempted.complete();
    if (shouldFail) {
      throw StateError('delete rejected');
    }
  }
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
