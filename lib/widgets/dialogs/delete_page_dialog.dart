import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/collab/strategy_presence_provider.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';

/// Asks before the page [pageId] is deleted. If teammates are on it right
/// now, as far as presence knows, it says who first: the page goes from
/// under them. Presence is best-effort, so this only warns; confirming
/// always deletes. Returns whether the user confirmed.
Future<bool> confirmDeletePage(
  BuildContext context,
  WidgetRef ref, {
  required String pageId,
  required String pageName,
}) {
  final names = [
    for (final peer in ref.read(strategyPresenceProvider).peopleOn(pageId))
      peer.name,
  ];
  return ConfirmAlertDialog.show(
    context: context,
    title: "Delete '$pageName'?",
    content: names.isEmpty
        ? "Are you sure you want to delete this page? This action cannot be "
            "undone."
        : "${_peopleHere(names)} on this page right now. Delete it anyway? "
            "This action cannot be undone.",
    confirmText: names.isEmpty ? "Delete" : "Delete anyway",
    cancelText: "Cancel",
    isDestructive: true,
  );
}

/// "Alex is", "Alex and Sam are", "Alex, Sam and 2 others are".
String _peopleHere(List<String> names) => switch (names) {
      [final only] => '$only is',
      [final first, final second] => '$first and $second are',
      [final first, final second, ...final rest] =>
        '$first, $second and ${rest.length} '
            '${rest.length == 1 ? 'other' : 'others'} are',
      [] => '',
    };
