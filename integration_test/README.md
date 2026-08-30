# Profile benchmarks

Run the map interaction benchmarks against the Windows profile engine:

```powershell
flutter drive `
  --driver=test_driver/performance_test.dart `
  --target=integration_test/map_drag_performance_test.dart `
  --profile `
  -d windows
```

The run prints a compact `PERF_RESULT` line and writes the complete report to
`build/map_drag_performance.json`.

Compare builds using the same machine, viewport, Flutter version, and power
state. The Windows engine can report zero-valued raster durations through
`FrameTiming`; build-time percentiles remain valid, but use DevTools timeline
traces when raster-thread timing is required.
