import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/drive_build.dart';

const shadowReachable = !kIsWeb && (driveBuild || kDebugMode);

sealed class LibraryStoreSwitch {
  const LibraryStoreSwitch();
}

final class StoreSwitchOff extends LibraryStoreSwitch {
  const StoreSwitchOff();
}

final class StoreSwitchShadow extends LibraryStoreSwitch {
  const StoreSwitchShadow();
}

final class StoreSwitchMirror extends LibraryStoreSwitch {
  const StoreSwitchMirror();
}

sealed class CloudStoreSwitch {
  const CloudStoreSwitch();
}

final class CloudStoreOff extends CloudStoreSwitch {
  const CloudStoreOff();
}

final class CloudStoreShadow extends CloudStoreSwitch {
  const CloudStoreShadow({this.sends = false});

  final bool sends;
}

final class LibraryStoreLaunch {
  const LibraryStoreLaunch._(this.choice, this.cloud, this.otherArgs);

  static const shadowFlag = '--library-store=shadow';
  static const mirrorFlag = '--library-store=mirror';
  static const offFlag = '--library-store=off';
  static const cloudShadowFlag = '--cloud-store=shadow';
  static const cloudSendFlag = '--cloud-store=send';

  final LibraryStoreSwitch choice;
  final CloudStoreSwitch cloud;
  final List<String> otherArgs;

  static LibraryStoreLaunch parse(
    List<String> args, {
    required bool mayShadow,
  }) {
    final others = <String>[];
    LibraryStoreSwitch choice = const StoreSwitchOff();
    CloudStoreSwitch cloud = const CloudStoreOff();
    for (final argument in args) {
      switch (argument) {
        case shadowFlag:
          choice =
              mayShadow ? const StoreSwitchShadow() : const StoreSwitchOff();
        case mirrorFlag:
          choice =
              mayShadow ? const StoreSwitchMirror() : const StoreSwitchOff();
        case offFlag:
          choice = const StoreSwitchOff();
        case cloudShadowFlag:
          cloud = mayShadow ? const CloudStoreShadow() : const CloudStoreOff();
        case cloudSendFlag:
          cloud = mayShadow
              ? const CloudStoreShadow(sends: true)
              : const CloudStoreOff();
        case _:
          others.add(argument);
      }
    }
    return LibraryStoreLaunch._(choice, cloud, List.unmodifiable(others));
  }
}

final libraryStoreSwitchProvider = Provider<LibraryStoreSwitch>(
  (ref) => const StoreSwitchOff(),
);
