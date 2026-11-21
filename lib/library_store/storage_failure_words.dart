import 'package:icarus_library/icarus_library.dart';

enum StoreStep { opening, refusedSave, saveInDoubt, read, release }

String storageFailureWords(StorageFailure failure, StoreStep step) =>
    switch (failure) {
      NoRoomForCommit() =>
        'Icarus held this change back because storage looked too full to '
            'save it safely.',
      OutOfRoom() => switch (step) {
          StoreStep.opening =>
            "There isn't enough storage space to open your library.",
          StoreStep.refusedSave =>
            "There isn't enough storage space, so this change wasn't saved.",
          StoreStep.saveInDoubt =>
            'Storage ran out while saving, so this change may not have been '
                'saved.',
          StoreStep.read =>
            "There isn't enough storage space to read part of your library.",
          StoreStep.release =>
            "There isn't enough storage space, so Icarus couldn't confirm it "
                'closed your library.',
        },
      AbortedForQuota() =>
        'The browser ran out of storage while saving, so this change may be '
            'only partly saved.',
      NewerFormat() =>
        'This library uses a newer format than this version of Icarus '
            'understands. Update Icarus to open it.',
      DamagedLibrary() => switch (step) {
          StoreStep.opening =>
            "Icarus can't read this library file, so it can't open it.",
          StoreStep.read => "Icarus couldn't read part of your library.",
          StoreStep.release =>
            "Icarus met something in your library it couldn't read while "
                "closing it, so it couldn't confirm it closed your library.",
          StoreStep.refusedSave =>
            "Icarus met something in your library it couldn't read, so this "
                "change wasn't saved.",
          StoreStep.saveInDoubt =>
            "Icarus met something in your library it couldn't read while "
                'saving, so this change may not have been saved.',
        },
      LibraryFileGone() =>
        "Your library file is missing or empty, and a file named like "
            "SQLite's log or journal is beside it, so Icarus won't start a "
            'new library in its place.',
      BrowserLacks() =>
        "This browser can't keep your library safely, so Icarus won't store "
            'it here.',
      NoAnswer() => switch (step) {
          StoreStep.opening =>
            'Opening your library took too long, so Icarus stopped. Reload '
                'the page to try again.',
          StoreStep.read => 'Reading part of your library took too long.',
          StoreStep.refusedSave =>
            "Saving took too long, so this change wasn't saved.",
          StoreStep.saveInDoubt =>
            'Saving took too long, so this change may not have been saved.',
          StoreStep.release =>
            "Icarus couldn't confirm it closed your library. If another tab "
                "can't open it, close this one.",
        },
      LeaseEnded() ||
      StoreClosed() =>
        'Your library was closed. Reopen it to keep working.',
      EngineClosed() =>
        'Icarus stopped using this storage. Reopen your library to keep '
            'working.',
      StoreStopped(:final cause) => storageFailureWords(cause, step),
      KeyTooLong() ||
      NameNotAllowed() ||
      WouldNotReadBack() =>
        "Icarus couldn't save this change.",
      DeviceFailure() =>
        'Something went wrong reading or writing your library.',
    };
