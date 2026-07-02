import 'package:flutter_riverpod/flutter_riverpod.dart';

final libraryContextMenuDismissalProvider = StateProvider<int>((ref) => 0);

void dismissLibraryContextMenus(WidgetRef ref) {
  final notifier = ref.read(libraryContextMenuDismissalProvider.notifier);
  notifier.state++;
}
