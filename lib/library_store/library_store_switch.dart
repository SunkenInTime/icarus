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

final class LibraryStoreLaunch {
  const LibraryStoreLaunch._(this.choice, this.otherArgs);

  static const shadowFlag = '--library-store=shadow';
  static const offFlag = '--library-store=off';

  final LibraryStoreSwitch choice;
  final List<String> otherArgs;

  static LibraryStoreLaunch parse(
    List<String> args, {
    required bool mayShadow,
  }) {
    final others = <String>[];
    LibraryStoreSwitch choice = const StoreSwitchOff();
    for (final argument in args) {
      switch (argument) {
        case shadowFlag:
          choice =
              mayShadow ? const StoreSwitchShadow() : const StoreSwitchOff();
        case offFlag:
          choice = const StoreSwitchOff();
        case _:
          others.add(argument);
      }
    }
    return LibraryStoreLaunch._(choice, List.unmodifiable(others));
  }
}

final libraryStoreSwitchProvider = Provider<LibraryStoreSwitch>(
  (ref) => const StoreSwitchOff(),
);
