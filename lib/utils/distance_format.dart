/// Display distances in US statute miles; routing and geographic APIs use meters.
double metersToMiles(num meters) => meters / 1609.344;

String formatMiles(num meters) => '${metersToMiles(meters).toStringAsFixed(2)} mi';
