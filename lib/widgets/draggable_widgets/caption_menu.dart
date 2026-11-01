import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/editing_presence_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/dialogs/caption_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The placed item [id] on the page on screen, or null when it has gone.
PlacedWidget? placedItemById(ProviderContainer container, String id) {
  for (final items in <List<PlacedWidget>>[
    container.read(agentProvider),
    container.read(abilityProvider),
    container.read(textProvider),
    container.read(placedImageProvider).images,
    container.read(utilityProvider),
  ]) {
    for (final item in items) {
      if (item.id == id) return item;
    }
  }
  return null;
}

/// Writes [caption] onto the placed item [id] through its own provider, so
/// the edit lands in undo and reaches the cloud like any other.
void setCaption(ProviderContainer container, String id, String caption) {
  switch (placedItemById(container, id)) {
    case PlacedAgentNode():
      container.read(agentProvider.notifier).setCaption(id, caption);
    case PlacedAbility():
      container.read(abilityProvider.notifier).setCaption(id, caption);
    case PlacedText():
      container.read(textProvider.notifier).setCaption(id, caption);
    case PlacedImage():
      container.read(placedImageProvider.notifier).setCaption(id, caption);
    case PlacedUtility():
      container.read(utilityProvider.notifier).setCaption(id, caption);
    default:
      return;
  }
  container.read(strategyProvider.notifier).setUnsaved();
}

/// Where the caption dialog of an item opened.
typedef CaptionPlace = ({String? strategyId, String? pageId});

CaptionPlace currentCaptionPlace(ProviderContainer container) => (
      strategyId: container.read(strategyProvider).strategyId,
      pageId: container.read(strategyPageSessionProvider).activePageId,
    );

/// Writes [caption] onto the item [id] opened at [place], and says whether it
/// did. A teammate can delete the item, or its page, while the dialog is open,
/// and an item copied to another page keeps its id, so a note is only ever
/// written where it was started.
bool finishCaption(
  ProviderContainer container,
  String id,
  CaptionPlace place,
  String caption,
) {
  if (currentCaptionPlace(container) != place ||
      placedItemById(container, id) == null) {
    return false;
  }
  setCaption(container, id, caption);
  return true;
}

/// Create caption, or Edit caption on an item that has one.
List<ShadContextMenuItem> buildCaptionMenuItems(
  BuildContext context,
  WidgetRef ref,
  String id,
) {
  if (id.isEmpty) return const [];
  final container = ProviderScope.containerOf(context, listen: false);
  final current = placedItemById(container, id)?.caption ?? '';
  return [
    ShadContextMenuItem(
      leading: const Icon(LucideIcons.messageSquareText, size: 16),
      child: Text(current.isEmpty ? 'Create caption' : 'Edit caption'),
      onPressed: () async {
        final start = placedItemById(container, id)?.caption ?? '';
        final opened = container.read(openCaptionItemProvider.notifier);
        final place = currentCaptionPlace(container);
        opened.state = (pageId: place.pageId, id: id);
        final next = await showCaptionDialog(context, initial: start);
        opened.state = null;
        // The menu's widget may be gone by now, and the note is still wanted.
        if (next == null || finishCaption(container, id, place, next)) return;
        if (next == start) return;
        await Clipboard.setData(ClipboardData(text: next));
        Settings.showToast(
          message: "That item is gone, so your note wasn't saved. "
              "It's on your clipboard.",
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
      },
    ),
  ];
}
