import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile_sections.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CloudFolderPill extends ConsumerStatefulWidget {
  const CloudFolderPill({
    super.key,
    required this.folder,
  });

  final CloudFolderSummary folder;

  @override
  ConsumerState<CloudFolderPill> createState() => _CloudFolderPillState();
}

class _CloudFolderPillState extends ConsumerState<CloudFolderPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late final Animation<double> _scaleAnimation;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.03,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pillColor = Color.lerp(
      Settings.tacticalVioletTheme.card,
      Settings.tacticalVioletTheme.primary,
      0.55,
    )!;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _isHovered = true);
        _animationController.forward();
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        _animationController.reverse();
      },
      child: GestureDetector(
        onTap: () =>
            ref.read(folderProvider.notifier).updateID(widget.folder.publicId),
        child: AnimatedBuilder(
          animation: _scaleAnimation,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: pillColor,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: _isHovered
                        ? Colors.white.withValues(alpha: 0.55)
                        : Colors.white.withValues(alpha: 0.18),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: pillColor.withValues(alpha: 0.35),
                      blurRadius: _isHovered ? 10 : 6,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.folder_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Text(
                        widget.folder.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class CloudStrategyTile extends ConsumerStatefulWidget {
  const CloudStrategyTile({
    super.key,
    required this.strategy,
  });

  final CloudStrategySummary strategy;

  @override
  ConsumerState<CloudStrategyTile> createState() => _CloudStrategyTileState();
}

class _CloudStrategyTileState extends ConsumerState<CloudStrategyTile> {
  Color _highlightColor = Settings.tacticalVioletTheme.border;
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    final data = _CloudStrategyTileViewData.fromSummary(widget.strategy);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) =>
          setState(() => _highlightColor = Settings.tacticalVioletTheme.ring),
      onExit: (_) =>
          setState(() => _highlightColor = Settings.tacticalVioletTheme.border),
      child: AbsorbPointer(
        absorbing: _isLoading,
        child: GestureDetector(
          onTap: () => _openStrategy(context),
          child: Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                decoration: BoxDecoration(
                  color: ShadTheme.of(context).colorScheme.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _highlightColor, width: 2),
                ),
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    Expanded(
                      child:
                          StrategyTileThumbnail(assetPath: data.thumbnailAsset),
                    ),
                    const SizedBox(height: 10),
                    Expanded(child: _CloudStrategyTileDetails(data: data)),
                  ],
                ),
              ),
              const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Icon(
                    Icons.cloud_done_outlined,
                    color: Colors.white70,
                    size: 22,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openStrategy(BuildContext context) async {
    if (_isLoading) {
      return;
    }

    setState(() => _isLoading = true);
    _showLoadingOverlay();
    var dismissedOverlay = false;

    try {
      await ref
          .read(strategyProvider.notifier)
          .openStrategy(widget.strategy.publicId);
      if (!context.mounted) {
        return;
      }
      Navigator.pop(context);
      dismissedOverlay = true;
      await Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 200),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (context, animation, _) => const StrategyView(),
          transitionsBuilder: (context, animation, _, child) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.9, end: 1.0)
                    .chain(CurveTween(curve: Curves.easeOut))
                    .animate(animation),
                child: child,
              ),
            );
          },
        ),
      );
    } finally {
      if (!dismissedOverlay && context.mounted) {
        Navigator.pop(context);
      }
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showLoadingOverlay() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
  }
}

class _CloudStrategyTileViewData {
  const _CloudStrategyTileViewData({
    required this.name,
    required this.mapName,
    required this.thumbnailAsset,
    required this.updatedLabel,
  });

  factory _CloudStrategyTileViewData.fromSummary(CloudStrategySummary summary) {
    final mapName = summary.mapData.trim();
    final normalizedMap = mapName.isEmpty
        ? 'unknown'
        : mapName.toLowerCase().replaceAll(' ', '_');
    return _CloudStrategyTileViewData(
      name: summary.name,
      mapName: mapName.isEmpty
          ? 'Unknown'
          : mapName[0].toUpperCase() + mapName.substring(1),
      thumbnailAsset: 'assets/maps/thumbnails/${normalizedMap}_thumbnail.webp',
      updatedLabel: _timeAgo(summary.updatedAt),
    );
  }

  final String name;
  final String mapName;
  final String thumbnailAsset;
  final String updatedLabel;

  static String _timeAgo(DateTime date) {
    final difference = DateTime.now().difference(date);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) {
      final minutes = difference.inMinutes;
      return '$minutes min${minutes == 1 ? '' : 's'} ago';
    }
    if (difference.inHours < 24) {
      final hours = difference.inHours;
      return '$hours hour${hours == 1 ? '' : 's'} ago';
    }
    if (difference.inDays < 30) {
      final days = difference.inDays;
      return '$days day${days == 1 ? '' : 's'} ago';
    }
    final months = (difference.inDays / 30).floor();
    return '$months month${months == 1 ? '' : 's'} ago';
  }
}

class _CloudStrategyTileDetails extends StatelessWidget {
  const _CloudStrategyTileDetails({
    required this.data,
  });

  final _CloudStrategyTileViewData data;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ShadTheme.of(context).colorScheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
        boxShadow: const [Settings.cardForegroundBackdrop],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: Text(
                    data.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(data.mapName),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Settings.tacticalVioletTheme.primary
                        .withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Settings.tacticalVioletTheme.primary
                          .withValues(alpha: 0.5),
                    ),
                  ),
                  child: const Text(
                    'Online',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Synced',
                style: TextStyle(color: Colors.deepPurpleAccent),
              ),
              const SizedBox(height: 5),
              Text(data.updatedLabel, overflow: TextOverflow.ellipsis),
            ],
          ),
        ],
      ),
    );
  }
}
