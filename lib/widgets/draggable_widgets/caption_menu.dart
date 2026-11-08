import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
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

/// The longest note an item can keep.
const captionMaxLength = 2000;

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

/// Where a note was started.
typedef CaptionPlace = ({String? strategyId, String? pageId});

CaptionPlace currentCaptionPlace(ProviderContainer container) => (
      strategyId: container.read(strategyProvider).strategyId,
      pageId: container.read(strategyPageSessionProvider).activePageId,
    );

/// Writes [caption] onto the item [id] opened at [place], and says whether it
/// did. A teammate can delete the item, or its page, while it is being written,
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

/// Create caption, or Edit caption on an item that has one. Either opens the
/// item's card with its note ready to write in place.
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
      onPressed: () => container
          .read(captionCardProvider.notifier)
          .startWriting(id, currentCaptionPlace(container)),
    ),
  ];
}
