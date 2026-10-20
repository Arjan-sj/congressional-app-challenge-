enum MapLayer {
  schools('Schools'),
  sidewalks('Sidewalks'),
  walkingPaths('Walking paths'),
  crossings('Crossings'),
  bikePaths('Bike paths'),
  bikeLanes('Bike lanes'),
  hazards('Hazards');

  const MapLayer(this.label);
  final String label;
}
