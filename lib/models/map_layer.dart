enum MapLayer {
  schools('Schools'),
  sidewalks('Sidewalks'),
  crossings('Crossings'),
  bikePaths('Bike paths'),
  bikeLanes('Bike lanes'),
  hazards('Hazards');

  const MapLayer(this.label);
  final String label;
}
