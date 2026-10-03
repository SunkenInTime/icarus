import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:icarus/providers/collab/lineup_editing_presence_provider.dart';
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
      padding: const EdgeInsets.only(top: 6),
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
              lineUpEditorsText(editors, lineups: lineups),
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Sam is editing this lineup right now." and its plural forms.
String lineUpEditorsText(List<PresencePeer> editors, {bool lineups = false}) {
  final what = lineups ? 'these lineups' : 'this lineup';
  final who = switch (editors) {
    [final one] => '${one.name} is',
    [final a, final b] => '${a.name} and ${b.name} are',
    [final a, ...final rest] => '${a.name} and ${rest.length} others are',
    [] => '',
  };
  return '$who editing $what right now.';
}
