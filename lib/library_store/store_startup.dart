import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_store.dart';

typedef StoreStartup = ({
  Future<LibraryStoreOpened>? opening,
  bool localShadow,
  bool cloudShadow,
});

StoreStartup openStores(
  ProviderContainer container,
  LibraryStoreLaunch launch, {
  required String? hiveDirectory,
  required bool allowsLocalLibrary,
  required String build,
}) {
  final localShadow = launch.choice is! StoreSwitchOff && allowsLocalLibrary;
  final cloudShadow = launch.cloud is CloudStoreShadow;
  return (
    opening: switch (hiveDirectory) {
      final String directory when localShadow || cloudShadow => container
          .read(libraryStoreProvider.notifier)
          .open(libraryStoreFile(directory), build: cloudShadow ? build : ''),
      _ => null,
    },
    localShadow: localShadow,
    cloudShadow: cloudShadow,
  );
}

void beginCloudShadow(
  ProviderContainer container,
  StoreStartup startup, {
  required String build,
}) {
  if (startup
      case (opening: final opening?, cloudShadow: true, localShadow: _)) {
    unawaited(
      container
          .read(cloudShadowProvider.notifier)
          .begin(opening: opening, build: build),
    );
  }
}
