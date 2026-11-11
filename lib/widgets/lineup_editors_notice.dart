import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/collab/editing_presence_provider.dart';
import 'package:icarus/widgets/strategy_presence.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Who else is editing the lineups a dialog shows, so the user knows before
/// changing them that edits made at the same time will conflict. Nothing
/// when no one is.
///
/// [itemId] is any lineup, origin or landing the dialog shows: they are all
/// in one lineup group, and the group is what teammates edit.
class LineUpEditorsNotice extends ConsumerWidget {
  const LineUpEditorsNotice({
    super.key,
    required this.itemId,
    this.lineups = false,
  });

  final String itemId;

  /// The dialog shows several lineups rather than one.
  final bool lineups;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editors = ref.watch(lineupGroupEditorsProvider(itemId));
    if (editors.isEmpty) return const SizedBox.shrink();
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: presenceColorFor(editors.first.uid),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              lineUpEditorsText(context.l10n, editors, lineups: lineups),
              // The label role: 12px/600.
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Sam is editing this lineup right now." and its plural forms.
String lineUpEditorsText(
  AppLocalizations l10n,
  List<PresencePeer> editors, {
  bool lineups = false,
}) =>
    switch (editors) {
      [final one] => lineups
          ? l10n.lineupEditorsOneOnLineups(one.name)
          : l10n.lineupEditorsOneOnLineup(one.name),
      [final a, final b] => lineups
          ? l10n.lineupEditorsTwoOnLineups(a.name, b.name)
          : l10n.lineupEditorsTwoOnLineup(a.name, b.name),
      [final a, ...final rest] => lineups
          ? l10n.lineupEditorsManyOnLineups(a.name, rest.length)
          : l10n.lineupEditorsManyOnLineup(a.name, rest.length),
      [] => '',
    };
