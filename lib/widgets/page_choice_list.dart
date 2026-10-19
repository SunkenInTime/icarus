import 'package:flutter/material.dart';
import 'package:icarus/services/video_export/video_export_source.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The open strategy's pages as a checklist, numbered in order: which pages
/// a video export plays or a screenshot captures. Needs a Material ancestor
/// for its ink.
class PageChoiceList extends StatelessWidget {
  const PageChoiceList({
    super.key,
    required this.pages,
    required this.selectedPageIds,
    required this.onToggle,
    this.maxHeight = 236,
  });

  final List<VideoExportPageChoice> pages;
  final Set<String> selectedPageIds;
  final ValueChanged<String> onToggle;

  /// Taller lists scroll.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (index, page) in pages.indexed) ...[
                if (index > 0) Container(height: 1, color: colors.border),
                InkWell(
                  mouseCursor: SystemMouseCursors.click,
                  onTap: () => onToggle(page.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        ShadCheckbox(
                          value: selectedPageIds.contains(page.id),
                          onChanged: (_) => onToggle(page.id),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 18,
                          child: Text(
                            '${index + 1}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.mutedForeground,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            page.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
