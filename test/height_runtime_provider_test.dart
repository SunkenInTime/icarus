import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/height_runtime_provider.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/height_native.dart';

import 'height_runtime_test_support.dart';
import 'display_warp_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.FragmentProgram program;
  setUpAll(() async {
    appProviderContainer = ProviderContainer();
    program =
        await ui.FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
  });
  tearDownAll(() => appProviderContainer.dispose());

  ProviderContainer containerFor(TestHeightDependencies dependencies,
          {bool badNavigation = false}) =>
      ProviderContainer(overrides: [
        heightRuntimeDependenciesProvider.overrideWithValue(dependencies),
        mapProvider.overrideWith(_Map.new),
        navigationGeometryProvider.overrideWith((ref, map) async {
          if (badNavigation) throw StateError('navigation failed');
          return testHeightNavigation;
        }),
      ]);

  test('mismatched display artwork fails before opening native data', () async {
    final deps = TestHeightDependencies(program);
    deps.assets.displayWarp = DisplayWarp.fromJson(
        displayWarpFixture(projection: deps.assets.projection));
    final container = containerFor(deps);
    container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    await expectLater(
        container.read(heightRuntimeProvider(MapValue.split).future),
        throwsFormatException);
    expect(deps.svgLoads, 2);
    expect(deps.openCalls, 0);
    container.dispose();
    await closeHeightRuntimes();
  });

  test('current map stays warm without cones and releases when the map changes',
      () async {
    final deps = TestHeightDependencies(program);
    final container = containerFor(deps);
    final lease =
        container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    final runtime =
        await container.read(heightRuntimeProvider(MapValue.split).future);
    expect(runtime.worker, same(deps.worker));
    expect(deps.worker.closeCalls, 0);
    lease.close();
    await container.pump();
    expect(deps.worker.closeCalls, 0);
    expect(container.read(heightRuntimeProvider(MapValue.split)).requireValue,
        same(runtime));
    container.read(mapProvider.notifier).updateMap(MapValue.ascent);
    await container.pump();
    await closeHeightRuntimes();
    expect(deps.worker.closeCalls, 1);
    container.dispose();
  });

  test('map disposal during asset loading never opens a native worker',
      () async {
    final deps = TestHeightDependencies(program)
      ..releaseAssets = Completer<void>();
    final container = containerFor(deps);
    container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    await deps.assetStarted.future;
    container.dispose();
    var closed = false;
    final closing = closeHeightRuntimes().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    deps.releaseAssets!.complete();
    await closing;
    expect(deps.openCalls, 0);
    expect(deps.svgLoads, 0);
  });

  test(
      'map disposal while the worker opens closes the orphan before load finishes',
      () async {
    final deps = TestHeightDependencies(program)
      ..releaseWorker = Completer<void>();
    final container = containerFor(deps);
    var published = false;
    container.listen(heightRuntimeProvider(MapValue.split), (_, next) {
      if (next.hasValue) published = true;
    });
    await deps.workerStarted.future;
    container.dispose();
    deps.releaseWorker!.complete();
    await closeHeightRuntimes();
    expect(published, isFalse);
    expect(deps.worker.closeCalls, 1);
  });

  test('application shutdown waits for opening workers and closes them',
      () async {
    final deps = TestHeightDependencies(program)
      ..releaseWorker = Completer<void>();
    final container = containerFor(deps);
    container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    final loading =
        container.read(heightRuntimeProvider(MapValue.split).future);
    await deps.workerStarted.future;
    var closed = false;
    final closing = closeHeightRuntimes().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    deps.releaseWorker!.complete();
    final runtime = await loading;
    await closing;
    expect(deps.worker.closeCalls, 1);
    await expectLater(
        runtime.queue
            .request('cone', Float64List.fromList([0, 0, 1.75, 1, 0, 10, 1])),
        throwsStateError);
    container.dispose();
  });

  test(
      'close cancels mounted consumers before draining the active native query',
      () async {
    final deps = TestHeightDependencies(program);
    final container = containerFor(deps);
    container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    final runtime =
        await container.read(heightRuntimeProvider(MapValue.split).future);
    deps.worker.releaseCompute = Completer<void>();
    final result = runtime.queue
        .request('cone', Float64List.fromList([0, 0, 1.75, 1, 0, 10, 1]));
    await deps.worker.computeStarted.future;
    final closing = runtime.close();
    expect(runtime.close(), same(closing));
    expect(await result, isNull);
    expect(deps.worker.closeCalls, 0);
    deps.worker.releaseCompute!.complete();
    await closing;
    expect(deps.worker.closeCalls, 1);
    container.dispose();
  });

  test(
      'navigation failure is handled while the independent asset load is pending',
      () async {
    final deps = TestHeightDependencies(program)
      ..releaseAssets = Completer<void>();
    final container = containerFor(deps, badNavigation: true);
    container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    final failed = expectLater(
        container.read(heightRuntimeProvider(MapValue.split).future),
        throwsStateError);
    await deps.assetStarted.future;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    deps.releaseAssets!.complete();
    await failed;
    expect(deps.openCalls, 0);
    container.dispose();
    await closeHeightRuntimes();
  });

  test(
      'failed native close still removes the runtime from the shutdown registry',
      () async {
    final deps = TestHeightDependencies(program);
    final container = containerFor(deps);
    container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    final runtime =
        await container.read(heightRuntimeProvider(MapValue.split).future);
    deps.worker.closeError = StateError('close failed');
    await expectLater(runtime.close(), throwsStateError);
    expect(runtime.renderer.residentImages, 0);
    await closeHeightRuntimes();
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(deps.worker.closeCalls, 1);
  });

  test('primary worker failure closes the already opened upper worker',
      () async {
    final deps = _ChartDependencies(program)..failPrimary = true;
    final container = containerFor(deps);
    container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    await expectLater(
        container.read(heightRuntimeProvider(MapValue.split).future),
        throwsStateError);
    expect(deps.upperWorker.closeCalls, 1);
    expect(deps.worker.closeCalls, 0);
    container.dispose();
    await closeHeightRuntimes();
    expect(deps.upperWorker.closeCalls, 1);
  });

  test('disposal during upper worker opening never opens the primary worker',
      () async {
    final deps = _ChartDependencies(program)..releaseUpper = Completer<void>();
    final container = containerFor(deps);
    container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    await deps.upperStarted.future;
    container.dispose();
    deps.releaseUpper!.complete();
    await closeHeightRuntimes();
    expect(deps.upperWorker.closeCalls, 1);
    expect(deps.openCalls, 0);
  });

  test('capture waits for both charts and shutdown drains both workers',
      () async {
    final deps = _ChartDependencies(program);
    final container = containerFor(deps);
    container.listen(heightRuntimeProvider(MapValue.split), (_, __) {});
    final runtime =
        await container.read(heightRuntimeProvider(MapValue.split).future);
    deps.worker.releaseCompute = Completer<void>();
    deps.upperWorker.releaseCompute = Completer<void>();
    final query = Float64List.fromList([0, 0, 1.75, 1, 0, 10, 1]);
    final lowerResult = runtime.queue.request('lower', query);
    final upperResult = runtime.variants.single.queue.request('upper', query);
    await Future.wait([
      deps.worker.computeStarted.future,
      deps.upperWorker.computeStarted.future,
    ]);
    var idle = false;
    final waiting = runtime.waitIdle().then((_) => idle = true);
    deps.worker.releaseCompute!.complete();
    await lowerResult;
    await Future<void>.delayed(Duration.zero);
    expect(idle, isFalse);
    var closed = false;
    final closing = runtime.close().then((_) => closed = true);
    expect(await upperResult, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(deps.upperWorker.closeCalls, 0);
    deps.upperWorker.releaseCompute!.complete();
    await Future.wait([waiting, closing]);
    expect(idle, isTrue);
    expect(deps.worker.closeCalls, 1);
    expect(deps.upperWorker.closeCalls, 1);
    container.dispose();
    await closeHeightRuntimes();
  });
}

class _ChartDependencies extends TestHeightDependencies {
  _ChartDependencies(super.program) {
    assets.variants.add(upperAssets);
  }
  final upperAssets = TestHeightAssets();
  final upperWorker = TestHeightWorker();
  final upperStarted = Completer<void>();
  Completer<void>? releaseUpper;
  bool failPrimary = false;

  @override
  Future<HeightNativeWorker> openWorker(HeightAssets assets) async {
    if (identical(assets, upperAssets)) {
      upperStarted.complete();
      await releaseUpper?.future;
      return upperWorker;
    }
    if (failPrimary) throw StateError('Primary worker could not open.');
    return super.openWorker(assets);
  }
}

class _Map extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.split, isAttack: true);
}
