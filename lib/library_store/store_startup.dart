import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus_library/icarus_library.dart' show LibraryStore;

typedef StoreStartup = ({
  Future<LibraryStoreOpened>? opening,
  bool localShadow,
  bool cloudSends,
});

StoreStartup openStores(
  ProviderContainer container,
  LibraryStoreLaunch launch, {
  required String? hiveDirectory,
  required bool allowsLocalLibrary,
  required String build,
  Future<LibraryStoreOpened>? alreadyOpening,
}) {
  final localShadow = launch.choice is! StoreSwitchOff &&
      launch.choice is! StoreSwitchStore &&
      allowsLocalLibrary;
  final cloudSends = launch.cloud is CloudStoreSend;
  return (
    opening: alreadyOpening ??
        switch (hiveDirectory) {
          final String directory when localShadow || cloudSends => container
              .read(libraryStoreProvider.notifier)
              .open(libraryStoreFile(directory),
                  build: cloudSends ? build : ''),
          _ => null,
        },
    localShadow: localShadow,
    cloudSends: cloudSends,
  );
}

void beginCloudSender(
  ProviderContainer container,
  StoreStartup startup, {
  required String build,
}) {
  if (startup
      case (
        opening: final opening?,
        cloudSends: true,
        localShadow: _,
      )) {
    unawaited(
      container.read(cloudSenderProvider.notifier).noteOpening(opening),
    );
    void sendOn(LibraryStore store) {
      final running = container.read(cloudSenderProvider);
      if (running != null && identical(running.store.store, store)) return;
      if (running != null) container.invalidate(cloudSenderProvider);
      container.read(cloudSenderProvider.notifier).begin(store, build: build);
    }

    container.listen(
      libraryStoreProvider,
      (_, next) {
        if (next case LibraryStoreReady(:final store)) sendOn(store);
      },
      fireImmediately: true,
    );
  }
}
