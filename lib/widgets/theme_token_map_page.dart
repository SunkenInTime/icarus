import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/ui_theme_provider.dart';
import 'package:icarus/theme/theme_color_format.dart';
import 'package:icarus/theme/ui_theme_models.dart';
import 'package:icarus/theme/ui_theme_tokens.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ThemeTokenMapPage extends ConsumerWidget {
  const ThemeTokenMapPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final effectiveTheme = ref.watch(effectiveUiThemeProvider);
    final mapPalette = ref.watch(effectiveMapThemePaletteProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Theme Token Map'),
        backgroundColor: Settings.tacticalVioletTheme.card,
        foregroundColor: Settings.tacticalVioletTheme.cardForeground,
      ),
      body: Container(
        color: Settings.tacticalVioletTheme.background,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Live mapping reference for UI, gameplay, shadows, and map colors.',
                    style: ShadTheme.of(context).textTheme.small.copyWith(
                          color: Settings.tacticalVioletTheme.mutedForeground,
                        ),
                  ),
                  const SizedBox(height: 16),
                  _ColorTokenSection(
                    title: 'Shad Theme Core',
                    tokenIds: const [
                      UiThemeTokenIds.shadBackground,
                      UiThemeTokenIds.shadForeground,
                      UiThemeTokenIds.shadCard,
                      UiThemeTokenIds.shadCardForeground,
                      UiThemeTokenIds.shadPopover,
                      UiThemeTokenIds.shadPopoverForeground,
                      UiThemeTokenIds.shadSecondary,
                      UiThemeTokenIds.shadMuted,
                      UiThemeTokenIds.shadMutedForeground,
                      UiThemeTokenIds.shadPrimary,
                      UiThemeTokenIds.shadPrimaryForeground,
                      UiThemeTokenIds.shadRing,
                      UiThemeTokenIds.shadSelection,
                      UiThemeTokenIds.shadDestructive,
                      UiThemeTokenIds.shadDestructiveForeground,
                      UiThemeTokenIds.shadBorder,
                      UiThemeTokenIds.shadInput,
                    ],
                    effectiveTheme: effectiveTheme,
                  ),
                  const SizedBox(height: 14),
                  _ColorTokenSection(
                    title: 'Layout and UI Constants',
                    tokenIds: const [
                      UiThemeTokenIds.sidebarSurface,
                      UiThemeTokenIds.sidebarHighlight,
                      UiThemeTokenIds.abilityBg,
                      UiThemeTokenIds.mapBackdropCenter,
                      UiThemeTokenIds.mapTileOverlay,
                      UiThemeTokenIds.swatchOutline,
                      UiThemeTokenIds.swatchSelected,
                      UiThemeTokenIds.textCardBackground,
                      UiThemeTokenIds.imageCardBackground,
                      UiThemeTokenIds.backdropOverlay,
                    ],
                    effectiveTheme: effectiveTheme,
                  ),
                  const SizedBox(height: 14),
                  _ColorTokenSection(
                    title: 'Game Context (Agent and Strategy)',
                    tokenIds: const [
                      UiThemeTokenIds.enemyBg,
                      UiThemeTokenIds.allyBg,
                      UiThemeTokenIds.enemyOutline,
                      UiThemeTokenIds.allyOutline,
                      UiThemeTokenIds.attackBadge,
                      UiThemeTokenIds.defendBadge,
                      UiThemeTokenIds.mixedBadge,
                      UiThemeTokenIds.favoriteOn,
                      UiThemeTokenIds.favoriteOff,
                      UiThemeTokenIds.favoriteRemove,
                    ],
                    effectiveTheme: effectiveTheme,
                  ),
                  const SizedBox(height: 14),
                  _ShadowTokenSection(effectiveTheme: effectiveTheme),
                  const SizedBox(height: 14),
                  _MapColorSection(
                    baseColor: mapPalette.baseColor,
                    detailColor: mapPalette.detailColor,
                    highlightColor: mapPalette.highlightColor,
                  ),
                  const SizedBox(height: 14),
                  _LivePreviewSection(effectiveTheme: effectiveTheme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorTokenSection extends StatelessWidget {
  const _ColorTokenSection({
    required this.title,
    required this.tokenIds,
    required this.effectiveTheme,
  });

  final String title;
  final List<String> tokenIds;
  final UiThemeResolvedData effectiveTheme;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: title,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final tokenId in tokenIds)
            _ColorTokenCard(
              token: UiThemeTokenRegistry.colorById(tokenId),
              color: effectiveTheme.color(tokenId),
            ),
        ],
      ),
    );
  }
}

class _ColorTokenCard extends StatelessWidget {
  const _ColorTokenCard({required this.token, required this.color});

  final UiColorTokenDefinition token;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final onColor =
        color.computeLuminance() > 0.55 ? Colors.black : Colors.white;

    return Container(
      width: 250,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: Settings.tacticalVioletTheme.border),
                ),
                alignment: Alignment.center,
                child: Text(
                  ThemeColorFormat.toHex(color),
                  style: TextStyle(
                    color: onColor,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(token.label),
                    Text(
                      token.id,
                      style: ShadTheme.of(context).textTheme.small.copyWith(
                            color: Settings.tacticalVioletTheme.mutedForeground,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            token.usageDescription,
            style: ShadTheme.of(context).textTheme.small,
          ),
          const SizedBox(height: 4),
          Text(
            'Affects: ${token.affectedElements.join(', ')}',
            style: ShadTheme.of(context).textTheme.small.copyWith(
                  color: Settings.tacticalVioletTheme.mutedForeground,
                ),
          ),
        ],
      ),
    );
  }
}

class _ShadowTokenSection extends StatelessWidget {
  const _ShadowTokenSection({required this.effectiveTheme});

  final UiThemeResolvedData effectiveTheme;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Shadow Tokens',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final token in UiThemeTokenRegistry.shadowTokens)
            _ShadowTokenCard(
              token: token,
              layers: effectiveTheme.shadowLayers(token.id),
            ),
        ],
      ),
    );
  }
}

class _ShadowTokenCard extends StatelessWidget {
  const _ShadowTokenCard({
    required this.token,
    required this.layers,
  });

  final UiShadowTokenDefinition token;
  final List<UiShadowLayerDefinition> layers;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(token.label),
          Text(
            token.id,
            style: ShadTheme.of(context).textTheme.small.copyWith(
                  color: Settings.tacticalVioletTheme.mutedForeground,
                ),
          ),
          const SizedBox(height: 8),
          Container(
            height: 56,
            decoration: BoxDecoration(
              color: Settings.tacticalVioletTheme.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Settings.tacticalVioletTheme.border),
            ),
            child: Center(
              child: Container(
                width: 120,
                height: 30,
                decoration: BoxDecoration(
                  color: Settings.tacticalVioletTheme.card,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow:
                      layers.map((layer) => layer.toBoxShadow()).toList(),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Preview',
                  style: ShadTheme.of(context).textTheme.small,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            token.usageDescription,
            style: ShadTheme.of(context).textTheme.small,
          ),
          const SizedBox(height: 4),
          Text(
            'Affects: ${token.affectedElements.join(', ')}',
            style: ShadTheme.of(context).textTheme.small.copyWith(
                  color: Settings.tacticalVioletTheme.mutedForeground,
                ),
          ),
        ],
      ),
    );
  }
}

class _MapColorSection extends StatelessWidget {
  const _MapColorSection({
    required this.baseColor,
    required this.detailColor,
    required this.highlightColor,
  });

  final Color baseColor;
  final Color detailColor;
  final Color highlightColor;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Map Colors (Separate Map Theme System)',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _MapColorCard(
            label: 'Base',
            usage: 'Map base regions and larger fills.',
            color: baseColor,
          ),
          _MapColorCard(
            label: 'Detail',
            usage: 'Map detail regions and secondary structures.',
            color: detailColor,
          ),
          _MapColorCard(
            label: 'Highlight',
            usage: 'Map accents and highlight regions.',
            color: highlightColor,
          ),
        ],
      ),
    );
  }
}

class _MapColorCard extends StatelessWidget {
  const _MapColorCard({
    required this.label,
    required this.usage,
    required this.color,
  });

  final String label;
  final String usage;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 8),
          Container(
            height: 50,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Settings.tacticalVioletTheme.border),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            ThemeColorFormat.toHex(color),
            style: ShadTheme.of(context).textTheme.small,
          ),
          Text(
            usage,
            style: ShadTheme.of(context).textTheme.small.copyWith(
                  color: Settings.tacticalVioletTheme.mutedForeground,
                ),
          ),
        ],
      ),
    );
  }
}

class _LivePreviewSection extends StatelessWidget {
  const _LivePreviewSection({required this.effectiveTheme});

  final UiThemeResolvedData effectiveTheme;

  @override
  Widget build(BuildContext context) {
    final primary = effectiveTheme.color(UiThemeTokenIds.shadPrimary);
    final primaryForeground =
        effectiveTheme.color(UiThemeTokenIds.shadPrimaryForeground);
    final destructive = effectiveTheme.color(UiThemeTokenIds.shadDestructive);
    final destructiveForeground =
        effectiveTheme.color(UiThemeTokenIds.shadDestructiveForeground);
    final sidebar = effectiveTheme.color(UiThemeTokenIds.sidebarSurface);
    final highlight = effectiveTheme.color(UiThemeTokenIds.sidebarHighlight);
    final enemyBg = effectiveTheme.color(UiThemeTokenIds.enemyBg);
    final allyBg = effectiveTheme.color(UiThemeTokenIds.allyBg);
    final enemyOutline = effectiveTheme.color(UiThemeTokenIds.enemyOutline);
    final allyOutline = effectiveTheme.color(UiThemeTokenIds.allyOutline);

    return _SectionCard(
      title: 'Live Context Previews',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _PreviewCard(
            title: 'Primary CTA',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Save Strategy',
                style: TextStyle(
                  color: primaryForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          _PreviewCard(
            title: 'Destructive CTA',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: destructive,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Delete Strategy',
                style: TextStyle(
                  color: destructiveForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          _PreviewCard(
            title: 'Sidebar Item',
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: sidebar,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: highlight, width: 2),
              ),
              child: Text(
                'Menus, dialog borders, hover outlines',
                style: ShadTheme.of(context).textTheme.small,
              ),
            ),
          ),
          _PreviewCard(
            title: 'Agent Chips',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: enemyBg,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: enemyOutline, width: 2),
                  ),
                  child: const Text('Enemy'),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: allyBg,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: allyOutline, width: 2),
                  ),
                  child: const Text('Ally'),
                ),
              ],
            ),
          ),
          _PreviewCard(
            title: 'Card Shadow',
            child: Container(
              width: 180,
              height: 56,
              decoration: BoxDecoration(
                color: Settings.tacticalVioletTheme.card,
                borderRadius: BorderRadius.circular(10),
                boxShadow: effectiveTheme
                    .shadowLayers(UiThemeTokenIds.shadowCard)
                    .map((layer) => layer.toBoxShadow())
                    .toList(),
              ),
              alignment: Alignment.center,
              child: const Text('Card'),
            ),
          ),
          _PreviewCard(
            title: 'Folder Glow',
            child: Container(
              width: 180,
              height: 56,
              decoration: BoxDecoration(
                color: Settings.tacticalVioletTheme.card,
                borderRadius: BorderRadius.circular(10),
                boxShadow: effectiveTheme
                    .shadowLayers(UiThemeTokenIds.shadowFolderGlow)
                    .map(
                      (layer) => layer
                          .copyWith(
                            colorValue: layer.colorValue,
                          )
                          .toBoxShadow(),
                    )
                    .toList(),
              ),
              alignment: Alignment.center,
              child: const Text('Folder'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
        boxShadow: Settings.cardForegroundBackdropShadows,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: ShadTheme.of(context).textTheme.lead),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
