import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_listing.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/ops_follower.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/strategy/local_library_view.dart';

final class LibraryStoreStart {
  const LibraryStoreStart._(
    this.choice,
    this.mode,
    this.listing, {
    this.editFollower,
  });

  factory LibraryStoreStart.of(
    LibraryStoreSwitch choice, {
    required Duration Function() clock,
    StoreMirror Function() mirror = storeMirror,
  }) {
    switch (choice) {
      case StoreSwitchOff():
        return LibraryStoreStart._(choice, null, null);
      case StoreSwitchShadow():
        return LibraryStoreStart._(choice, const ShadowOnly(), null);
      case StoreSwitchMirror():
        return LibraryStoreStart._(choice, Mirroring(mirror()), null);
      case StoreSwitchRead():
        final mirroring = Mirroring(mirror());
        final listing = StoreLibraryListing(HiveLibraryListing(), clock: clock)
          ..follow(mirroring.mirror);
        return LibraryStoreStart._(choice, mirroring, listing);
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
          null,
          editFollower: follower,
        );
    }
  }

  final LibraryStoreSwitch choice;
  final ShadowMode? mode;
  final StoreLibraryListing? listing;
  final EditFollower? editFollower;

  List<Override> get overrides => [
        if (mode != null) libraryStoreSwitchProvider.overrideWithValue(choice),
        if (listing case final listing?)
          localLibraryListingProvider.overrideWithValue(listing),
      ];
}
