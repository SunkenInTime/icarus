enum TraversalSpeedProfile {
  running,
  walking,
  brimStim,
  neonRun,
}

class TraversalSpeed {
  static const TraversalSpeedProfile defaultProfile =
      TraversalSpeedProfile.running;

  // Persist enum profile IDs on drawings; resolve to tunable m/s at runtime.
  static const Map<TraversalSpeedProfile, double> metersPerSecond = {
    TraversalSpeedProfile.running: 6.75,
    TraversalSpeedProfile.walking: 4.5225,
    TraversalSpeedProfile.brimStim: 7.425,
    TraversalSpeedProfile.neonRun: 9.11,
  };
}
