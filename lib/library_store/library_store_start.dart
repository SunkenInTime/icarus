import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/ops_follower.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_mirror.dart';

final class LibraryStoreStart {
  const LibraryStoreStart._(this.choice, this.mode, {this.editFollower});

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
      case StoreSwitchOps():
        final journal = ActionJournal();
        final journaling = StoreMirror(
          reads: HiveReads(),
          betweenAnimations: betweenAnimations,
          actions: journal,
        );
        final follower = OpsFollower(journaling, () => appProviderContainer);
        return LibraryStoreStart._(
          choice,
          Mirroring(journaling),
          editFollower: follower,
        );
    }
  }

  final LibraryStoreSwitch choice;
  final ShadowMode? mode;
  final EditFollower? editFollower;

  List<Override> get overrides => [
        if (choice is! StoreSwitchOff)
          libraryStoreSwitchProvider.overrideWithValue(choice),
      ];
}
