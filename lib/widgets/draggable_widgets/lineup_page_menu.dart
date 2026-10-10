import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// "Move to page" and "Copy to page" for the lineups [links] (every lineup
/// at the spot the user right-clicked), each listing the strategy's other
/// pages. A spot one of them shares with a lineup that stays is copied, so
/// that lineup keeps it.
List<ShadContextMenuItem> buildLineUpPageMenuItems(
  WidgetRef ref,
  List<LineUpLink> links,
) {
  if (links.isEmpty) return const [];
  final notifier = ref.read(strategyProvider.notifier);
  final pages = notifier.lineUpPageTargets();
  if (pages.isEmpty) return const [];

  final linkIds = {for (final link in links) link.id};
  final what = links.length > 1
      ? '${links.length} lineups'
      : links.single.name.trim().isEmpty
          ? 'the lineup'
          : '“${links.single.name.trim()}”';

  Future<void> send(LineUpPageTarget page, {required bool move}) async {
    final result = await notifier.sendLineUpsToPage(
      linkIds: linkIds,
      pageId: page.id,
      move: move,
    );
    final nothing = move ? 'nothing was moved' : 'nothing was copied';
    switch (result) {
      case LineUpPageResult.done:
        Settings.showToast(
          message: '${move ? 'Moved' : 'Copied'} $what to ${page.name}.',
          backgroundColor: Settings.tacticalVioletTheme.primary,
        );
      case LineUpPageResult.copiedInstead:
        Settings.showToast(
          message: 'Copied $what to ${page.name}. This page changed '
              'meanwhile, so it is still here too.',
          backgroundColor: Settings.tacticalVioletTheme.primary,
        );
      case LineUpPageResult.unreachable:
        Settings.showToast(
          message: "Couldn't reach the cloud, so $nothing.",
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
      case LineUpPageResult.notSaved:
        Settings.showToast(
          message: "Couldn't save the change on this device, so $nothing.",
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
      case LineUpPageResult.unavailable:
        break;
    }
  }

  List<ShadContextMenuItem> pageItems({required bool move}) => [
        for (final page in pages)
          ShadContextMenuItem(
            trailing: page.offset.abs() == 1
                ? Text(
                    page.offset < 0 ? 'previous' : 'next',
                    style: TextStyle(
                      fontSize: 12,
                      color: Settings.tacticalVioletTheme.mutedForeground,
                    ),
                  )
                : null,
            onPressed: () => send(page, move: move),
            child: Text(page.name),
          ),
      ];

  return [
    ShadContextMenuItem(
      leading: const Icon(LucideIcons.fileInput, size: 16),
      trailing: const Icon(LucideIcons.chevronRight, size: 16),
      items: pageItems(move: true),
      child: Text(
        links.length > 1
            ? 'Move ${links.length} lineups to page'
            : 'Move to page',
      ),
    ),
    ShadContextMenuItem(
      leading: const Icon(LucideIcons.copyPlus, size: 16),
      trailing: const Icon(LucideIcons.chevronRight, size: 16),
      items: pageItems(move: false),
      child: Text(
        links.length > 1
            ? 'Copy ${links.length} lineups to page'
            : 'Copy to page',
      ),
    ),
  ];
}
