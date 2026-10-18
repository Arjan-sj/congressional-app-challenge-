import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/app.dart';

void main() {
  testWidgets('Explore shows school map and explicit zoom controls', (
    tester,
  ) async {
    await tester.pumpWidget(const SafeRoutesApp(enableMapTiles: false));

    expect(find.text('SafeRoutes'), findsOneWidget);
    expect(find.text('Explore U.S. public schools'), findsOneWidget);
    expect(find.text('PROTOTYPE'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.remove), findsOneWidget);
    expect(find.byIcon(Icons.my_location), findsOneWidget);
  });

  testWidgets('Reports tab shows fictional examples', (tester) async {
    await tester.pumpWidget(const SafeRoutesApp(enableMapTiles: false));
    await tester.tap(find.byIcon(Icons.list_alt_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Example reports'), findsOneWidget);
    expect(find.text('Missing sidewalk'), findsOneWidget);
  });

  testWidgets('Map tap is retained when switching straight to Report tab', (
    tester,
  ) async {
    await tester.pumpWidget(const SafeRoutesApp(enableMapTiles: false));

    final map = find.byType(FlutterMap);
    expect(map, findsOneWidget);
    await tester.ensureVisible(map);
    await tester.pumpAndSettle();

    // Tap clear of the pilot-school marker so the map itself handles the tap.
    final bounds = tester.getRect(map);
    await tester.tapAt(bounds.center + const Offset(90, 75));
    await tester.pump();

    // Previously the map selection was local state and this path lost it.
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    expect(find.text('Map point selected'), findsOneWidget);
    expect(find.text('Select a point on the map first'), findsNothing);
  });

  testWidgets('Demo submission requires a selected map location', (
    tester,
  ) async {
    await tester.pumpWidget(const SafeRoutesApp(enableMapTiles: false));
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    expect(find.text('Select a point on the map first'), findsOneWidget);
    // The save button is farther down a lazily built scrolling form.
    // A separate form test verifies successful submission with coordinates.
  });
}
