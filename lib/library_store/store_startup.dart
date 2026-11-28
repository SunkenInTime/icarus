import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus_library/icarus_library.dart' show LibraryStore;

typedef StoreStartup = ({
  Future<LibraryStoreOpened>? opening,
  bool cloudSends,
});

StoreStartup openStores(
  ProviderContainer container,
  LibraryStoreLaunch launch, {
  required String? hiveDirectory,
  required String build,
  Future<LibraryStoreOpened>? alreadyOpening,
}) {
  final cloudSends = launch.cloud is CloudStoreSend;
  return (
    opening: alreadyOpening ??
        switch (hiveDirectory) {
          final String directory when cloudSends => container
              .read(libraryStoreProvider.notifier)
              .open(libraryStoreFile(directory),
                  build: cloudSends ? build : ''),
          _ => null,
        },
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

Future<void> storeClosesBeforeExit(ProviderContainer container) =>
    container.read(libraryStoreProvider.notifier).close();

void closeLibraryStoreOnExit(ProviderContainer container) {
  AppLifecycleListener(
    onExitRequested: () async {
      await storeClosesBeforeExit(container);
      return ui.AppExitResponse.exit;
    },
  );
}
