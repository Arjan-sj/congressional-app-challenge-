import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/app.dart';

void main() {
  testWidgets('Explore shows pilot school and interactive map controls', (tester) async {
    await tester.pumpWidget(const SafeRoutesApp(enableMapTiles: false));

    expect(find.text('SafeRoutes'), findsOneWidget);
    expect(find.text('Explore school area'), findsOneWidget);
    expect(find.text('PROTOTYPE'), findsOneWidget);
    expect(find.byIcon(Icons.my_location), findsOneWidget);
  });

  testWidgets('Reports tab shows fictional examples', (tester) async {
    await tester.pumpWidget(const SafeRoutesApp(enableMapTiles: false));
    await tester.tap(find.byIcon(Icons.list_alt_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Example reports'), findsOneWidget);
    expect(find.text('Missing sidewalk'), findsOneWidget);
  });

  testWidgets('Demo submission requires a selected map location', (tester) async {
    await tester.pumpWidget(const SafeRoutesApp(enableMapTiles: false));
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    expect(find.text('Select a point on the map first'), findsOneWidget);
    // The save button is farther down a lazily built scrolling form.
    // A separate form test verifies successful submission with coordinates.
  });
}
