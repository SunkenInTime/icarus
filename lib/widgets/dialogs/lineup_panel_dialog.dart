import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/widgets/custom_text_field.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:icarus/widgets/line_up_media_carousel.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Opens the lineup panel for a landing spot or an origin: every lineup that
/// lands there (or throws from there) on the left, the selected one's media
/// on the right.
Future<void> showLineUpPanel(
  BuildContext context, {
  String? landingId,
  String? originId,
  String? initialLinkId,
}) {
  assert((landingId == null) != (originId == null));
  return showDialog<void>(
    context: context,
    builder: (context) => LineUpPanelDialog(
      landingId: landingId,
      originId: originId,
      initialLinkId: initialLinkId,
    ),
  );
}

/// Opens whatever fits a landing spot: one lineup goes straight to its
/// media, several open the panel.
Future<void> openLandingLineUps(
  BuildContext context,
  WidgetRef ref,
  String landingId,
) {
  final links = ref.read(lineUpProvider).linksToLanding(landingId);
  if (links.length == 1) {
    return showDialog<void>(
      context: context,
      builder: (context) => LineUpMediaCarousel(linkId: links.single.id),
    );
  }
  return showLineUpPanel(context, landingId: landingId);
}

String lineUpDisplayName(LineUpLink link, List<LineUpLink> siblings) {
  if (link.name.isNotEmpty) return link.name;
  final index = siblings.indexWhere((entry) => entry.id == link.id);
  return 'Lineup ${index < 0 ? siblings.length : index + 1}';
}

class LineUpPanelDialog extends ConsumerStatefulWidget {
  const LineUpPanelDialog({
    super.key,
    this.landingId,
    this.originId,
    this.initialLinkId,
  });

  final String? landingId;
  final String? originId;
  final String? initialLinkId;

  @override
  ConsumerState<LineUpPanelDialog> createState() => _LineUpPanelDialogState();
}

class _LineUpPanelDialogState extends ConsumerState<LineUpPanelDialog> {
  String? _selectedLinkId;
  final Object _hoverOwnerToken = Object();
  ProviderContainer? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  @override
  void initState() {
    super.initState();
    _selectedLinkId = widget.initialLinkId;
  }

  @override
  void dispose() {
    final container = _container;
    if (container != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        container
            .read(hoveredLineUpTargetProvider.notifier)
            .clearIfOwned(_hoverOwnerToken);
      });
    }
    super.dispose();
  }

  List<LineUpLink> _links(LineUpState state) {
    final landingId = widget.landingId;
    if (landingId != null) {
      final links = state.linksToLanding(landingId);
      final originOrder = <String, int>{
        for (final (index, origin) in state.origins.indexed) origin.id: index,
      };
      links.sort(
        (a, b) => (originOrder[a.originId] ?? 0)
            .compareTo(originOrder[b.originId] ?? 0),
      );
      return links;
    }
    return state.linksFromOrigin(widget.originId!);
  }

  Future<void> _rename(LineUpLink link) async {
    final controller = TextEditingController(text: link.name);
    final name = await showShadDialog<String>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('Rename lineup'),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
        child: SizedBox(
          width: 360,
          child: Material(
            color: Colors.transparent,
            child: CustomTextField(
              controller: controller,
              hintText:
                  'Optional, for telling this apart from other lineups here',
            ),
          ),
        ),
      ),
    );
    controller.dispose();
    if (name == null || name == link.name) return;
    ref.read(lineUpProvider.notifier).updateLink(link.copyWith(name: name));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lineUpProvider);
    final links = _links(state);

    if (links.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }

    final selected = links.firstWhere(
      (link) => link.id == _selectedLinkId,
      orElse: () => links.first,
    );
    if (selected.id != _selectedLinkId) {
      _selectedLinkId = selected.id;
    }

    final landing =
        widget.landingId == null ? null : state.landingById(widget.landingId!);
    final origin =
        widget.originId == null ? null : state.originById(widget.originId!);
    final title = landing != null
        ? landing.ability.data.name
        : AgentData.agents[origin?.agent.type]?.name ?? 'Origin';
    final subtitle = landing != null
        ? '${links.length} lineups land here'
        : '${links.length} lineups from here';

    // The media is the point of this dialog, so it takes most of the window
    // and gives the pane whatever the list doesn't need.
    final window = MediaQuery.sizeOf(context);
    final bodyWidth = (window.width - 120).clamp(640.0, 1400.0);
    final bodyHeight = (window.height - 200).clamp(360.0, 900.0);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Navigator.of(context).maybePop();
        },
      },
      child: Focus(
        autofocus: true,
        child: ShadDialog(
          title: Text(title),
          description: Text(subtitle),
          constraints: BoxConstraints(maxWidth: bodyWidth + 48),
          child: SizedBox(
            width: bodyWidth,
            height: bodyHeight,
            child: Material(
              color: Colors.transparent,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 240,
                    child: ListView.separated(
                      itemCount: links.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final link = links[index];
                        return _LineUpRow(
                          link: link,
                          label: lineUpDisplayName(link, links),
                          agentName: AgentData
                                  .agents[state
                                      .originById(link.originId)
                                      ?.agent
                                      .type]
                                  ?.name ??
                              '',
                          isSelected: link.id == selected.id,
                          onTap: () =>
                              setState(() => _selectedLinkId = link.id),
                          onHoverEnter: () {
                            ref
                                .read(hoveredLineUpTargetProvider.notifier)
                                .setHoveredConnector(
                                  originId: link.originId,
                                  landingId: link.landingId,
                                  ownerToken: _hoverOwnerToken,
                                );
                          },
                          onHoverExit: () {
                            ref
                                .read(hoveredLineUpTargetProvider.notifier)
                                .clearIfOwned(_hoverOwnerToken);
                          },
                          onEditMedia: () {
                            showDialog(
                              context: context,
                              builder: (context) =>
                                  CreateLineupDialog(linkId: link.id),
                            );
                          },
                          onRename: () => _rename(link),
                          onDelete: () {
                            ref
                                .read(lineUpProvider.notifier)
                                .deleteLink(link.id);
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LineUpMediaPages(
                        key: ValueKey(selected.id),
                        images: selected.images,
                        youtubeLink: selected.youtubeLink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LineUpRow extends StatefulWidget {
  const _LineUpRow({
    required this.link,
    required this.label,
    required this.agentName,
    required this.isSelected,
    required this.onTap,
    required this.onHoverEnter,
    required this.onHoverExit,
    required this.onEditMedia,
    required this.onRename,
    required this.onDelete,
  });

  final LineUpLink link;
  final String label;
  final String agentName;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;
  final VoidCallback onEditMedia;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  State<_LineUpRow> createState() => _LineUpRowState();
}

class _LineUpRowState extends State<_LineUpRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final firstImage =
        widget.link.images.isEmpty ? null : widget.link.images.first;

    return ShadContextMenuRegion(
      items: [
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.pencil),
          onPressed: widget.onEditMedia,
          child: const Text('Edit media'),
        ),
        ShadContextMenuItem(
          leading: const Icon(LucideIcons.textCursorInput),
          onPressed: widget.onRename,
          child: const Text('Rename'),
        ),
        ShadContextMenuItem(
          leading: Icon(LucideIcons.trash2, color: theme.destructive),
          onPressed: widget.onDelete,
          child: const Text('Delete lineup'),
        ),
      ],
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          setState(() => _hovered = true);
          widget.onHoverEnter();
        },
        onExit: (_) {
          setState(() => _hovered = false);
          widget.onHoverExit();
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            key: ValueKey('lineup-panel-row-${widget.link.id}'),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: widget.isSelected || _hovered ? theme.accent : theme.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: widget.isSelected ? theme.primary : theme.border,
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 72,
                    height: 44,
                    child: _LineUpThumbnail(image: firstImage),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.agentName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.mutedForeground,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The first image of a lineup, or a muted glyph when it has none to show.
class _LineUpThumbnail extends ConsumerWidget {
  const _LineUpThumbnail({required this.image});

  final SimpleImageData? image;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = this.image;
    final imageProvider = image == null
        ? null
        : watchStrategyImageSource(
            ref,
            (id: image.id, fileExtension: image.fileExtension),
          ).imageProvider;
    if (imageProvider != null) {
      return Image(
        image: imageProvider,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    const theme = Settings.tacticalVioletTheme;
    return Container(
      color: theme.secondary,
      child: Icon(
        LucideIcons.image,
        size: 18,
        color: theme.mutedForeground,
      ),
    );
  }
}
