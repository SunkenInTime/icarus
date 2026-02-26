enum TraversalSpeedProfile {
  running,
}

class TraversalSpeed {
  static const TraversalSpeedProfile defaultProfile =
      TraversalSpeedProfile.running;

  // Persist enum profile IDs on drawings; resolve to tunable m/s at runtime.
  static const Map<TraversalSpeedProfile, double> metersPerSecond = {
    TraversalSpeedProfile.running: 6.75,
  };
}
