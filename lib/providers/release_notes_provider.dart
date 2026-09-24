import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/release_notes.dart';

final releaseNotesProvider = FutureProvider<List<ReleaseNotesEntry>>((ref) {
  return ReleaseNotes.fetch();
});
