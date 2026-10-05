import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/providers/collab/strategy_presence_provider.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/strategy_presence.dart';

/// Asks before the page [pageId] is deleted. If teammates are on it right
/// now, as far as presence knows, it says who first: the page goes from
/// under them. Presence is best-effort, so this only warns; confirming
/// always deletes. A cloud strategy's page can be restored from Recently
/// deleted for a while, and the dialog says so; a local one is gone for
/// good. Returns whether the user confirmed.
Future<bool> confirmDeletePage(
  BuildContext context,
  WidgetRef ref, {
  required String pageId,
  required String pageName,
}) {
  final peers = ref.read(strategyPresenceProvider).peopleOn(pageId).toList();
  final afterwards = ref.read(strategyProvider).source == StrategySource.cloud
      ? "You can restore it from Recently deleted for "
          "$pageTrashRetentionDays days."
      : "This action cannot be undone.";
  final warning = " on this page right now. Delete it anyway? $afterwards";
  return ConfirmAlertDialog.show(
    context: context,
    title: "Delete '$pageName'?",
    content: peers.isEmpty
        ? "Are you sure you want to delete this page? $afterwards"
        : "${_peopleHere([for (final peer in peers) peer.name])}$warning",
    // Each name in bold, in the colour their cursor has on the map.
    body: peers.isEmpty
        ? null
        : Text.rich(TextSpan(children: [
            ..._peopleHereSpans(peers),
            TextSpan(text: warning),
          ])),
    confirmText: peers.isEmpty ? "Delete" : "Delete anyway",
    cancelText: "Cancel",
    isDestructive: true,
  );
}

TextSpan _name(PresencePeer peer) => TextSpan(
      text: peer.name,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        color: presenceColorFor(peer.uid),
      ),
    );

/// [_peopleHere] with each named teammate styled by [_name].
List<InlineSpan> _peopleHereSpans(List<PresencePeer> peers) => switch (peers) {
      [final only] => [_name(only), const TextSpan(text: ' is')],
      [final first, final second] => [
          _name(first),
          const TextSpan(text: ' and '),
          _name(second),
          const TextSpan(text: ' are'),
        ],
      [final first, final second, ...final rest] => [
          _name(first),
          const TextSpan(text: ', '),
          _name(second),
          TextSpan(
            text: ' and ${rest.length} '
                '${rest.length == 1 ? 'other' : 'others'} are',
          ),
        ],
      [] => const [],
    };

/// "Alex is", "Alex and Sam are", "Alex, Sam and 2 others are".
String _peopleHere(List<String> names) => switch (names) {
      [final only] => '$only is',
      [final first, final second] => '$first and $second are',
      [final first, final second, ...final rest] =>
        '$first, $second and ${rest.length} '
            '${rest.length == 1 ? 'other' : 'others'} are',
      [] => '',
    };
