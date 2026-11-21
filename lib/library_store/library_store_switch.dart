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

final class LibraryStoreLaunchException implements Exception {
  const LibraryStoreLaunchException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class LibraryStoreLaunch {
  const LibraryStoreLaunch._(this.choice, this.otherArgs);

  static const optionName = '--library-store';

  final LibraryStoreSwitch choice;
  final List<String> otherArgs;

  static LibraryStoreLaunch parse(
    List<String> args, {
    required bool mayShadow,
  }) {
    final others = <String>[];
    String? asked;
    for (final argument in args) {
      if (!argument.startsWith('$optionName=')) {
        others.add(argument);
        continue;
      }
      if (asked != null && mayShadow) {
        throw const LibraryStoreLaunchException(
          '$optionName may only be supplied once.',
        );
      }
      asked = argument.substring(optionName.length + 1);
    }
    final LibraryStoreSwitch choice = switch ((asked, mayShadow)) {
      (null, _) || (_, false) || ('off', true) => const StoreSwitchOff(),
      ('shadow', true) => const StoreSwitchShadow(),
      (final other?, true) => throw LibraryStoreLaunchException(
          '$optionName is off or shadow, not "$other".',
        ),
    };
    return LibraryStoreLaunch._(choice, List.unmodifiable(others));
  }
}

final libraryStoreSwitchProvider = Provider<LibraryStoreSwitch>(
  (ref) => const StoreSwitchOff(),
);
