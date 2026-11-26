sealed class AutosaveBeforeExit {
  const AutosaveBeforeExit();
}

final class NothingLeftUnsaved extends AutosaveBeforeExit {
  const NothingLeftUnsaved();
}

final class EditedDuringTheAutosave extends AutosaveBeforeExit {
  const EditedDuringTheAutosave();
}

final class NotAutosaved extends AutosaveBeforeExit {
  const NotAutosaved(this.because);

  final NotAutosavedBecause because;
}

enum NotAutosavedBecause { autosaveIsOff, stillUnsaved }
