import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_mirror.dart';

final class LibraryStoreStart {
  const LibraryStoreStart._(this.choice, this.mode);

  factory LibraryStoreStart.of(
    LibraryStoreSwitch choice, {
    StoreMirror Function() mirror = storeMirror,
  }) {
    switch (choice) {
      case StoreSwitchOff() || StoreSwitchStore():
        return LibraryStoreStart._(choice, null);
      case StoreSwitchShadow():
        return LibraryStoreStart._(choice, const ShadowOnly());
      case StoreSwitchMirror():
        return LibraryStoreStart._(choice, Mirroring(mirror()));
    }
  }

  final LibraryStoreSwitch choice;
  final ShadowMode? mode;

  List<Override> get overrides => [
        if (choice is! StoreSwitchOff)
          libraryStoreSwitchProvider.overrideWithValue(choice),
      ];
}
