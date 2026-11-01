import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Shows an SVG asset. Use this instead of `SvgPicture.asset`.
///
/// On web an asset is a network request, so it can fail. flutter_svg never
/// forgets a failed load: `Cache.putIfAbsent` leaves it in `_pending`, every
/// later request for that asset gets the same failure until the page reloads,
/// and vector_graphics rethrows it as an unhandled error each time. So the read
/// happens here, where a failure can be shown and tried again, and those
/// packages are only ever handed bytes that arrived.
class AssetSvg extends StatefulWidget {
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

  /// Time between tries while the asset can't be read. Short enough that the
  /// picture comes back on its own moments after the connection does.
  static const retryDelay = Duration(seconds: 3);

  final String assetName;
  final double? width;
  final double? height;
  final BoxFit fit;
  final ColorMapper? colorMapper;
  final ColorFilter? colorFilter;
  final String? semanticsLabel;

  @override
  State<AssetSvg> createState() => _AssetSvgState();
}

class _AssetSvgState extends State<AssetSvg> {
  /// The bytes on screen. A new asset replaces them when it arrives, so
  /// switching sides doesn't blank the map for the length of a request.
  ({String name, ByteData bytes})? _loaded;
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AssetSvg oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetName != widget.assetName) {
      _retry?.cancel();
      _load();
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final name = widget.assetName;
    final arrived = _AssetSvgBytes.arrived[name];
    if (arrived != null) {
      _loaded = (name: name, bytes: arrived);
      return;
    }

    try {
      final bytes = await _AssetSvgBytes.load(name);
      if (!mounted || name != widget.assetName) return;
      setState(() => _loaded = (name: name, bytes: bytes));
    } catch (_) {
      if (!mounted || name != widget.assetName) return;
      setState(() => _loaded = null);
      _retry = Timer(AssetSvg.retryDelay, () {
        if (mounted) _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _loaded;
    if (loaded == null) {
      return SizedBox(width: widget.width, height: widget.height);
    }
    return SvgPicture(
      _ArrivedSvgLoader(
        loaded.name,
        loaded.bytes,
        colorMapper: widget.colorMapper,
      ),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      colorFilter: widget.colorFilter,
      semanticsLabel: widget.semanticsLabel,
    );
  }
}

/// Every SVG read so far, kept for the whole session. A strategy can go back to
/// a side or recolor a map with no connection, and all the app's SVGs together
/// are a few megabytes.
abstract final class _AssetSvgBytes {
  static final Map<String, ByteData> arrived = {};
  static final Map<String, Future<ByteData>> _reading = {};

  /// Assets whose last read failed.
  static final ValueNotifier<Set<String>> missing = ValueNotifier(const {});

  static Future<ByteData> load(String name) {
    return _reading[name] ??= _read(name).whenComplete(() {
      _reading.remove(name);
    });
  }

  static Future<ByteData> _read(String name) async {
    try {
      final bytes = await rootBundle.load(name);
      arrived[name] = bytes;
      if (missing.value.contains(name)) {
        missing.value = {...missing.value}..remove(name);
      }
      return bytes;
    } catch (_) {
      missing.value = {...missing.value, name};
      rethrow;
    }
  }
}

/// Caches under the asset's name like [SvgAssetLoader], but can't fail to read.
class _ArrivedSvgLoader extends SvgAssetLoader {
  const _ArrivedSvgLoader(super.assetName, this.bytes, {super.colorMapper});

  final ByteData bytes;

  @override
  Future<ByteData?> prepareMessage(BuildContext? context) =>
      SynchronousFuture<ByteData?>(bytes);
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
      valueListenable: _AssetSvgBytes.missing,
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
