import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/services/app_assets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Shows an SVG asset. Use this instead of `SvgPicture.asset`.
///
/// On web an asset is a network request, so it can fail. flutter_svg never
/// forgets a failed load: `Cache.putIfAbsent` leaves it in `_pending`, every
/// later request for that asset gets the same failure until the page reloads,
/// and vector_graphics rethrows it as an unhandled error each time. So the read
/// behind this picture goes through [appAssets] and doesn't fail: those packages
/// see a slow load that finishes by itself.
class AssetSvg extends StatelessWidget {
  const AssetSvg(
    this.assetName, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.colorMapper,
    this.colorFilter,
    this.semanticsLabel,
  });

  final String assetName;
  final double? width;
  final double? height;
  final BoxFit fit;
  final ColorMapper? colorMapper;
  final ColorFilter? colorFilter;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return SvgPicture(
      _WaitingSvgLoader(assetName, colorMapper: colorMapper),
      // Keyed so a picture that's still on its way can't leave the last asset
      // on screen, like the other side of the map under this side's items.
      key: ValueKey(assetName),
      width: width,
      height: height,
      fit: fit,
      colorFilter: colorFilter,
      semanticsLabel: semanticsLabel,
    );
  }
}

/// Caches under the asset's name like [SvgAssetLoader], but can't fail to read.
class _WaitingSvgLoader extends SvgAssetLoader {
  const _WaitingSvgLoader(super.assetName, {super.colorMapper});

  @override
  Future<ByteData?> prepareMessage(BuildContext? context) =>
      appAssets.load(assetName);
}

/// Says so when the map at [assetName] couldn't be read. It sits above the
/// placed items so they can't hide it. Saved work doesn't depend on the
/// artwork, so the strategy stays as it was and can still be edited.
class MissingMapNotice extends StatelessWidget {
  const MissingMapNotice(this.assetName, {super.key});

  final String assetName;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ValueListenableBuilder(
      valueListenable: appAssets.missing,
      builder: (context, missing, _) {
        if (!missing.contains(assetName)) return const SizedBox.shrink();
        return IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.card,
                border: Border.all(color: theme.colorScheme.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("Map didn't load", style: theme.textTheme.small),
                  const SizedBox(height: 8),
                  Text(
                    "Trying again. Your strategy isn't affected.",
                    style: theme.textTheme.muted,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
