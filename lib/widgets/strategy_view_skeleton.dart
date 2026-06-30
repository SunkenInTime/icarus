import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class StrategyViewSkeleton extends StatelessWidget {
  const StrategyViewSkeleton({
    super.key,
    this.strategyName,
    this.mapValue,
    this.isAttack = true,
  });

  final String? strategyName;
  final MapValue? mapValue;
  final bool isAttack;

  @override
  Widget build(BuildContext context) {
    final resolvedMap = mapValue ?? MapValue.ascent;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: _SkeletonShimmer(
          child: Column(
            children: [
              _SkeletonTopBar(
                strategyName: strategyName,
                mapValue: resolvedMap,
                isAttack: isAttack,
              ),
              Expanded(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: _MapCanvasSkeleton(
                        mapValue: resolvedMap,
                        isAttack: isAttack,
                      ),
                    ),
                    const Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: _FloatingControlSkeleton(),
                      ),
                    ),
                    const Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: _PagesBarSkeleton(),
                      ),
                    ),
                    const Align(
                      alignment: Alignment.centerRight,
                      child: _SidebarSkeleton(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkeletonShimmer extends StatefulWidget {
  const _SkeletonShimmer({required this.child});

  final Widget child;

  @override
  State<_SkeletonShimmer> createState() => _SkeletonShimmerState();
}

class _SkeletonShimmerState extends State<_SkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1350),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    if (disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return widget.child;
    }

    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final shimmerOffset =
                -bounds.width + bounds.width * 2 * _controller.value;
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Colors.transparent,
                Colors.white.withAlpha(34),
                Colors.transparent,
              ],
              stops: const [0.34, 0.5, 0.66],
            ).createShader(bounds.translate(shimmerOffset, 0));
          },
          child: child,
        );
      },
    );
  }
}

class _SkeletonTopBar extends StatelessWidget {
  const _SkeletonTopBar({
    required this.mapValue,
    required this.isAttack,
    this.strategyName,
  });

  final String? strategyName;
  final MapValue mapValue;
  final bool isAttack;

  @override
  Widget build(BuildContext context) {
    final title = strategyName?.trim();
    return Padding(
      padding: const EdgeInsets.only(left: 15, top: 15, bottom: 10, right: 15),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const _SkeletonBlock(width: 40, height: 40, radius: 8),
              const SizedBox(width: 5),
              _MapSelectorSkeleton(mapValue: mapValue, isAttack: isAttack),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              width: 280,
              height: 40,
              decoration: BoxDecoration(
                color: _tone(Settings.tacticalVioletTheme.card, 0.95),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _tone(Settings.highlightColor, 0.82)),
              ),
              child: Center(
                child: title == null || title.isEmpty
                    ? const _SkeletonBlock(width: 158, height: 12, radius: 5)
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ShadTheme.of(
                            context,
                          ).textTheme.small.copyWith(color: Colors.white70),
                        ),
                      ),
              ),
            ),
          ),
          const _SkeletonBlock(width: 238, height: 40, radius: 8),
        ],
      ),
    );
  }
}

class _MapSelectorSkeleton extends StatelessWidget {
  const _MapSelectorSkeleton({required this.mapValue, required this.isAttack});

  final MapValue mapValue;
  final bool isAttack;

  @override
  Widget build(BuildContext context) {
    final mapName = Maps.mapNames[mapValue] ?? Maps.mapNames[MapValue.ascent]!;
    return Container(
      width: 262,
      height: 65,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Settings.tacticalVioletTheme.border,
          width: 2,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 180,
              height: 57,
              child: ColorFiltered(
                colorFilter: _grayscaleFilter,
                child: Opacity(
                  opacity: 0.62,
                  child: Image.asset(
                    'assets/maps/thumbnails/${mapName}_thumbnail.webp',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isAttack ? CustomIcons.sword : Icons.shield,
                  size: 20,
                  color: Settings.tacticalVioletTheme.mutedForeground,
                ),
                const SizedBox(height: 2),
                _SkeletonBlock(width: isAttack ? 36 : 44, height: 8, radius: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MapCanvasSkeleton extends StatelessWidget {
  const _MapCanvasSkeleton({required this.mapValue, required this.isAttack});

  final MapValue mapValue;
  final bool isAttack;

  @override
  Widget build(BuildContext context) {
    final mapName = Maps.mapNames[mapValue] ?? Maps.mapNames[MapValue.ascent]!;
    final assetName =
        'assets/maps/${mapName}_map${isAttack ? "" : "_defense"}.svg';

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final worldWidth = height * (16 / 9);
        final playAreaSize = Size(worldWidth, height);
        final coordinateSystem = CoordinateSystem(playAreaSize: playAreaSize);
        final viewportWidth =
            (constraints.maxWidth - Settings.sideBarReservedWidth)
                .clamp(0.0, constraints.maxWidth)
                .toDouble();
        final mapWidth = height * coordinateSystem.mapAspectRatio;
        final mapLeft = (worldWidth - mapWidth) / 2;
        final worldLeft = (viewportWidth - worldWidth) / 2;

        return Row(
          children: [
            SizedBox(
              width: viewportWidth,
              height: height,
              child: Container(
                width: viewportWidth,
                height: height,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.5,
                    colors: [
                      const Color(0xff18181b),
                      ShadTheme.of(context).colorScheme.background,
                    ],
                  ),
                ),
                child: ClipRect(
                  child: Stack(
                    children: [
                      Positioned(
                        left: worldLeft,
                        top: 0,
                        width: worldWidth,
                        height: height,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            const Positioned.fill(
                              child: Padding(
                                padding: EdgeInsets.all(4),
                                child: DotGrid(),
                              ),
                            ),
                            Positioned(
                              left: mapLeft,
                              top: 0,
                              width: mapWidth,
                              height: height,
                              child: ColorFiltered(
                                colorFilter: _grayscaleFilter,
                                child: Opacity(
                                  opacity: 0.46,
                                  child: SvgPicture.asset(
                                    assetName,
                                    semanticsLabel: 'Map',
                                    fit: BoxFit.contain,
                                  ),
                                ),
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
            SizedBox(width: Settings.sideBarReservedWidth, height: height),
          ],
        );
      },
    );
  }
}

class _FloatingControlSkeleton extends StatelessWidget {
  const _FloatingControlSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        _SkeletonBlock(width: 40, height: 40, radius: 8),
        SizedBox(width: 8),
        _SkeletonBlock(width: 40, height: 40, radius: 8),
        SizedBox(width: 8),
        _SkeletonBlock(width: 40, height: 40, radius: 8),
        SizedBox(width: 8),
        _SkeletonBlock(width: 40, height: 40, radius: 8),
      ],
    );
  }
}

class _PagesBarSkeleton extends StatelessWidget {
  const _PagesBarSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 224,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _tone(Settings.tacticalVioletTheme.card, 0.9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _tone(Settings.highlightColor, 0.88)),
      ),
      child: const Row(
        children: [
          _SkeletonBlock(width: 34, height: 34, radius: 6),
          SizedBox(width: 8),
          Expanded(child: _SkeletonBlock(height: 34, radius: 6)),
          SizedBox(width: 8),
          _SkeletonBlock(width: 34, height: 34, radius: 6),
        ],
      ),
    );
  }
}

class _SidebarSkeleton extends StatelessWidget {
  const _SidebarSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: Settings.sideBarReservedWidth,
      child: Padding(
        padding: const EdgeInsets.only(
          left: Settings.sideBarPanelPaddingLeft,
          right: Settings.sideBarPanelPaddingRight,
          bottom: 8,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: Settings.sideBarPanelWidth,
            decoration: BoxDecoration(
              color: Settings.tacticalVioletTheme.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color.fromRGBO(210, 214, 219, 0.1),
                width: 2,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: _SkeletonBlock(width: 58, height: 24, radius: 5),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 5,
                    mainAxisSpacing: 5,
                    crossAxisSpacing: 5,
                    children: List.generate(
                      9,
                      (_) => const _SkeletonBlock(radius: 8),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: _SkeletonBlock(width: 72, height: 24, radius: 5),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 8,
                    bottom: 10,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              _SkeletonBlock(width: 176, height: 36, radius: 6),
                              SizedBox(width: 8),
                              _SkeletonBlock(width: 40, height: 40, radius: 8),
                            ],
                          ),
                          SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              _SkeletonBlock(width: 42, height: 13, radius: 4),
                              SizedBox(height: 8),
                              _SkeletonBlock(width: 50, height: 13, radius: 4),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: SizedBox(
                      width: Settings.sideBarContentWidth,
                      child: GridView.count(
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 10, right: 10),
                        crossAxisCount: 4,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        children: List.generate(
                          20,
                          (_) => const _SkeletonBlock(radius: 8),
                        ),
                      ),
                    ),
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

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({this.width, this.height, this.radius = 8});

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _tone(Settings.tacticalVioletTheme.secondary, 0.74),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: _tone(Settings.highlightColor, 0.45)),
      ),
    );
  }
}

const ColorFilter _grayscaleFilter = ColorFilter.matrix(<double>[
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
]);

Color _tone(Color color, double opacity) {
  return color.withAlpha((opacity * 255).round().clamp(0, 255));
}
