import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/screenshot/persistent_offscreen_renderer.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class _LifecycleCounts {
  int initialized = 0;
  int disposed = 0;
}

class _LifecycleColor extends StatefulWidget {
  const _LifecycleColor({
    required this.color,
    required this.counts,
  });

  final Color color;
  final _LifecycleCounts counts;

  @override
  State<_LifecycleColor> createState() => _LifecycleColorState();
}

class _LifecycleColorState extends State<_LifecycleColor> {
  @override
  void initState() {
    super.initState();
    widget.counts.initialized++;
  }

  @override
  void dispose() {
    widget.counts.disposed++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 8,
        height: 8,
        child: ColoredBox(color: widget.color),
      );
}

class _DelayedColor extends StatefulWidget {
  const _DelayedColor();

  @override
  State<_DelayedColor> createState() => _DelayedColorState();
}

class _DelayedColorState extends State<_DelayedColor> {
  Color color = Colors.red;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 5), () {
      if (mounted) setState(() => color = Colors.blue);
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 8,
        height: 8,
        child: ColoredBox(color: color),
      );
}

Future<Color> _topLeftPixel(Uint8List pngBytes) async {
  final codec = await ui.instantiateImageCodec(pngBytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final bytes = data!.buffer.asUint8List();
      return Color.fromARGB(bytes[3], bytes[0], bytes[1], bytes[2]);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

Future<void> _disposeRenderer(
  WidgetTester tester,
  PersistentOffscreenRenderer renderer,
) =>
    renderer.dispose(waitForFrame: () => tester.pump());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(8, 8));
  });

  testWidgets('reuses the element and render trees between captures',
      (tester) async {
    final counts = _LifecycleCounts();
    var wrapperCalls = 0;
    final renderer = PersistentOffscreenRenderer(
      targetSize: const Size(8, 8),
      wrapWidget: (child) {
        wrapperCalls++;
        return child;
      },
    );

    try {
      final frames = await tester.runAsync(() async {
        final first = await renderer.capture(
          _LifecycleColor(color: Colors.red, counts: counts),
        );
        final second = await renderer.capture(
          _LifecycleColor(color: Colors.blue, counts: counts),
        );
        final raw = await renderer.captureRawRgba(
          _LifecycleColor(color: Colors.green, counts: counts),
        );
        return (
          pngColors: [
            await _topLeftPixel(first),
            await _topLeftPixel(second),
          ],
          rawColor: Color.fromARGB(raw[3], raw[0], raw[1], raw[2]),
          rawLength: raw.length,
        );
      });

      expect(counts.initialized, 1);
      expect(counts.disposed, 0);
      expect(wrapperCalls, 1);
      expect(frames!.pngColors[0].toARGB32(), Colors.red.toARGB32());
      expect(frames.pngColors[1].toARGB32(), Colors.blue.toARGB32());
      expect(frames.rawColor.toARGB32(), Colors.green.toARGB32());
      expect(frames.rawLength, 8 * 8 * 4);
    } finally {
      await _disposeRenderer(tester, renderer);
    }

    expect(counts.disposed, 1);
  });

  testWidgets('prepare flushes async updates before capture', (tester) async {
    final renderer = PersistentOffscreenRenderer(
      targetSize: const Size(8, 8),
    );

    try {
      final color = await tester.runAsync(() async {
        await renderer.prepare(
          const _DelayedColor(),
          settleDuration: const Duration(milliseconds: 20),
        );
        final bytes = await renderer.capture(const _DelayedColor());
        return _topLeftPixel(bytes);
      });

      expect(color!.toARGB32(), Colors.blue.toARGB32());
    } finally {
      await _disposeRenderer(tester, renderer);
    }
  });

  testWidgets('teardown drains focus and provider callbacks before disposal',
      (tester) async {
    CoordinateSystem.instance.setIsScreenshot(true);
    addTearDown(() => CoordinateSystem.instance.setIsScreenshot(false));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final renderer = PersistentOffscreenRenderer(
      targetSize: const Size(8, 8),
      wrapWidget: (child) => UncontrolledProviderScope(
        container: container,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(8, 8)),
          child: MaterialApp(home: child),
        ),
      ),
    );

    await tester.runAsync(() {
      return renderer.capture(
        MouseWatch(
          deleteTarget: HoveredDeleteTarget.agent(
            id: 'agent-id',
            ownerToken: Object(),
          ),
          child: const SizedBox(width: 8, height: 8),
        ),
      );
    });
    await _disposeRenderer(tester, renderer);
    await tester.pump();
  });
}
