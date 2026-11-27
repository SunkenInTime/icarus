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

final class StoreSwitchOps extends LibraryStoreSwitch {
  const StoreSwitchOps();
}

final class StoreSwitchStore extends LibraryStoreSwitch {
  const StoreSwitchStore();
}

sealed class CloudStoreSwitch {
  const CloudStoreSwitch();
}

final class CloudStoreOff extends CloudStoreSwitch {
  const CloudStoreOff();
}

final class CloudStoreSend extends CloudStoreSwitch {
  const CloudStoreSend();
}

final class LibraryStoreLaunch {
  const LibraryStoreLaunch._(this.choice, this.cloud, this.otherArgs);

  static const shadowFlag = '--library-store=shadow';
  static const mirrorFlag = '--library-store=mirror';
  static const readFlag = '--library-store=read';
  static const opsFlag = '--library-store=ops';
  static const storeFlag = '--library-store=store';
  static const offFlag = '--library-store=off';
  static const cloudStoreFlag = '--cloud-store=';
  static const cloudSendFlag = '${cloudStoreFlag}send';
  static const cloudShadowFlag = '${cloudStoreFlag}shadow';

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
        case readFlag:
          choice = const StoreSwitchOff();
        case opsFlag:
          choice = mayShadow ? const StoreSwitchOps() : const StoreSwitchOff();
        case storeFlag:
          choice =
              mayShadow ? const StoreSwitchStore() : const StoreSwitchOff();
        case offFlag:
          choice = const StoreSwitchOff();
        case cloudSendFlag:
          cloud = mayShadow ? const CloudStoreSend() : const CloudStoreOff();
        case final unknown when unknown.startsWith(cloudStoreFlag) && mayShadow:
          throw ArgumentError.value(
            unknown,
            'args',
            '--cloud-store has no value '
                '"${unknown.substring(cloudStoreFlag.length)}"; it takes send',
          );
        case cloudShadowFlag:
          cloud = const CloudStoreOff();
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

final cloudStoreSwitchProvider = Provider<CloudStoreSwitch>(
  (ref) => const CloudStoreOff(),
);
