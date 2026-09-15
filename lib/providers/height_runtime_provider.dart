import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/height_cached_renderer.dart';
import 'package:icarus/view_cone/height_native.dart';
import 'package:icarus/view_cone/height_query_queue.dart';
import 'package:icarus/view_cone/receiver_mask.dart';

/// File and native-worker operations stay separate from provider ownership so
/// map changes can cancel a load without handing an orphaned worker to the UI.
class HeightRuntimeDependencies {
  const HeightRuntimeDependencies();

  Future<HeightAssets> loadAssets(MapValue map) => loadHeightAssets(map);
  Future<String> loadSvg(MapValue map, {required bool isAttack}) =>
      rootBundle.loadString(
          'assets/maps/${map.name}_map${isAttack ? '' : '_defense'}.svg');
  Future<ui.FragmentProgram> loadProgram() =>
      ui.FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
  Future<HeightNativeWorker> openWorker(HeightAssets assets) =>
      HeightNativeWorker.open(heightNativeLibraryPath(), assets.folder, 4);
}

final heightRuntimeDependenciesProvider = Provider<HeightRuntimeDependencies>(
    (ref) => const HeightRuntimeDependencies());

final heightRuntimeProvider = FutureProvider.autoDispose
    .family<HeightRuntime, MapValue>((ref, map) => _trackHeightLoad(() async {
          var disposed = false;
          HeightRuntime? runtime;
          final variants = <HeightRuntime>[];
          void Function()? releaseRetention;
          ref.onDispose(() {
            disposed = true;
            if (runtime != null) {
              unawaited(
                  runtime.close().catchError((Object error, StackTrace stack) {
                AppErrorReporter.reportError(
                    'Could not release the previous map sightlines.',
                    error: error,
                    stackTrace: stack,
                    source: 'HeightRuntime.dispose');
              }));
            }
          });
          try {
            ref.listen(mapProvider.select((state) => state.currentMap),
                (before, current) {
              if (current != map) {
                releaseRetention?.call();
                releaseRetention = null;
              } else if (runtime != null && releaseRetention == null) {
                releaseRetention = ref.keepAlive().close;
              }
            });
            final dependencies = ref.watch(heightRuntimeDependenciesProvider);
            final navigationFuture =
                ref.watch(navigationGeometryProvider(map).future);
            // Attach both error handlers before either independent load can complete.
            final inputs = await Future.wait<Object?>([
              navigationFuture,
              dependencies.loadAssets(map),
            ]);
            final navigation = inputs[0] as NavigationGeometryMap?;
            final assets = inputs[1] as HeightAssets;
            if (disposed)
              throw StateError('Map changed while loading sightlines.');
            if (navigation == null)
              throw StateError('Map navigation is unavailable.');
            if (navigation.geometry.maximumGroundChartId >
                assets.variants.length) {
              throw StateError(
                  'Navigation refers to a missing sightline chart.');
            }
            final artwork = await Future.wait([
              dependencies.loadSvg(map, isAttack: true),
              dependencies.loadSvg(map, isAttack: false),
            ]);
            final displayWarp = assets.displayWarp;
            if (displayWarp != null) {
              await verifyDisplayWarpArtwork(
                  displayWarp, artwork[0], artwork[1]);
            }
            final attack = WorldReceiverMask.parse(artwork[0]);
            final defense = WorldReceiverMask.parse(artwork[1]);
            final program = await dependencies.loadProgram();
            if (disposed)
              throw StateError('Map changed while loading sightlines.');
            for (final variant in assets.variants) {
              final worker = await dependencies.openWorker(variant);
              variants.add(HeightRuntime(
                  variant, navigation, attack, defense, program, worker));
              if (disposed) {
                throw StateError('Map changed while loading sightlines.');
              }
            }
            final worker = await dependencies.openWorker(assets);
            runtime = HeightRuntime(
                assets, navigation, attack, defense, program, worker,
                variants: List.unmodifiable(variants));
            if (disposed) {
              await runtime.close();
              throw StateError('Map changed while loading sightlines.');
            }
            // Keep the current map warm across pages with no cones. Other maps release
            // their native data when their final consumer or capture lease leaves.
            if (ref.read(mapProvider).currentMap == map) {
              releaseRetention = ref.keepAlive().close;
            }
            return runtime;
          } catch (error, stack) {
            await Future.wait(
                [for (final variant in variants) variant.close()]);
            if (!disposed) {
              AppErrorReporter.reportError(
                  'Could not load sightlines for ${map.name}. View cones are hidden for this map.',
                  error: error,
                  stackTrace: stack,
                  source: 'heightRuntimeProvider.${map.name}');
            }
            rethrow;
          }
        }));

final _heightLoads = <Future<HeightRuntime>>{};
final _heightRuntimes = <HeightRuntime>{};
Future<HeightRuntime> _trackHeightLoad(
    Future<HeightRuntime> Function() load) async {
  final future = load();
  _heightLoads.add(future);
  try {
    return await future;
  } finally {
    _heightLoads.remove(future);
  }
}

Future<void> closeHeightRuntimes() async {
  await Future.wait([
    for (final load in _heightLoads.toList())
      load.then<void>((_) {}, onError: (Object _, StackTrace __) {})
  ]);
  await Future.wait(
      [for (final runtime in _heightRuntimes.toList()) runtime.close()]);
}

class HeightRuntime {
  HeightRuntime(this.assets, this.navigation, this.attack, this.defense,
      this.program, this.worker, {this.variants = const []})
      : queue = HeightQueryQueue(worker.compute,
            onError: (error, stack) => AppErrorReporter.reportError(
                'Could not calculate this sightline. Reload the map to try again.',
                error: error,
                stackTrace: stack,
                source: 'HeightRuntime.query')) {
    _heightRuntimes.add(this);
  }
  final HeightAssets assets;
  final NavigationGeometryMap navigation;
  final WorldReceiverMask attack, defense;
  final ui.FragmentProgram program;
  final HeightNativeWorker worker;
  final HeightQueryQueue queue;
  final List<HeightRuntime> variants;
  final renderer = WorldHeightCachedRenderer();
  Future<void>? _closing;

  Future<void> waitIdle() async {
    await Future.wait(
        [queue.waitIdle(), for (final variant in variants) variant.waitIdle()]);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    try {
      await Future.wait(
          [queue.close(), for (final variant in variants) variant.close()]);
    } finally {
      renderer.dispose();
      try {
        await worker.close();
      } finally {
        _heightRuntimes.remove(this);
      }
    }
  }
}
