import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/l10n/l10n.dart';
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
  final l10n = context.l10n;
  final peers = ref.read(strategyPresenceProvider).peopleOn(pageId).toList();
  final afterwards = ref.read(strategyProvider).source == StrategySource.cloud
      ? l10n.deletePageRestorableFor(pageTrashRetentionDays)
      : l10n.deletePageCannotUndo;
  return ConfirmAlertDialog.show(
    context: context,
    title: l10n.deletePageTitle(pageName),
    content: peers.isEmpty
        ? l10n.deletePageConfirm(afterwards)
        : _peopleHere(l10n, [for (final peer in peers) peer.name], afterwards),
    // Each name in bold, in the colour their cursor has on the map.
    body: peers.isEmpty
        ? null
        : Text.rich(
            TextSpan(children: _peopleHereSpans(l10n, peers, afterwards))),
    confirmText:
        peers.isEmpty ? l10n.commonDelete : l10n.deletePageDeleteAnyway,
    cancelText: l10n.commonCancel,
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

/// [_peopleHere] with each named teammate styled by [_name]: the warning is
/// built with a marker in place of each name, then cut at the markers.
List<InlineSpan> _peopleHereSpans(
  AppLocalizations l10n,
  List<PresencePeer> peers,
  String afterwards,
) {
  final named = peers.take(2).toList();
  final markers = [for (var i = 0; i < named.length; i++) '\u{E000}$i\u{E000}'];
  final warning = _peopleHere(
    l10n,
    [...markers, for (final peer in peers.skip(2)) peer.name],
    afterwards,
  );
  final spans = <InlineSpan>[];
  var rest = warning;
  while (rest.isNotEmpty) {
    final at = rest.indexOf('\u{E000}');
    if (at < 0) {
      spans.add(TextSpan(text: rest));
      break;
    }
    if (at > 0) spans.add(TextSpan(text: rest.substring(0, at)));
    final end = rest.indexOf('\u{E000}', at + 1);
    spans.add(_name(named[int.parse(rest.substring(at + 1, end))]));
    rest = rest.substring(end + 1);
  }
  return spans;
}

/// "Alex is on this page right now…", "Alex and Sam are…", "Alex, Sam and 2
/// others are…", followed by [afterwards].
String _peopleHere(
  AppLocalizations l10n,
  List<String> names,
  String afterwards,
) =>
    switch (names) {
      [final only] => l10n.deletePagePeerOne(only, afterwards),
      [final first, final second] =>
        l10n.deletePagePeersTwo(first, second, afterwards),
      [final first, final second, ...final rest] =>
        l10n.deletePagePeersMany(first, second, rest.length, afterwards),
      [] => '',
    };
