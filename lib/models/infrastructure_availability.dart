/// Availability describes the current viewport and requested layer set only.
enum InfrastructureAvailability {
  notRequested,
  loading,
  available,
  empty,
  unavailable,
  cached,
}

/// Complete means the requested OSM query completed, not that real-world
/// sidewalks or paths have all been mapped. Indexed regional coverage may be
/// unknown even when some mapped features are available.
enum InfrastructureCoverage { complete, partial, unknown, unavailable }

class InfrastructureStatus {
  const InfrastructureStatus({
    this.availability = InfrastructureAvailability.notRequested,
    this.coverage = InfrastructureCoverage.unknown,
    this.hasValidCache = false,
    this.lastAttemptFailed = false,
    this.retryAt,
    this.isEmpty = false,
  });

  final InfrastructureAvailability availability;
  final InfrastructureCoverage coverage;
  final bool hasValidCache;
  final bool lastAttemptFailed;
  final DateTime? retryAt;
  final bool isEmpty;

  bool get showLayerControls => !lastAttemptFailed || hasValidCache;
  bool get hasCurrentData =>
      hasValidCache ||
      availability == InfrastructureAvailability.available ||
      availability == InfrastructureAvailability.empty;
}
