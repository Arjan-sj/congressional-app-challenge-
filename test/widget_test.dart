import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/app.dart';

void main() {
  testWidgets('Explore shows school map and explicit zoom controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SafeRoutesApp(
        enableMapTiles: false,
        persistAccessibilityPreferences: false,
      ),
    );

    expect(find.text('SafeRoutes'), findsOneWidget);
    expect(find.text('SCHOOL & COMMUNITY SUPPORT'), findsOneWidget);
    expect(find.text('Explore local safety infrastructure'), findsOneWidget);
    expect(find.text('Search schools and communities'), findsOneWidget);
    expect(find.text('Map information in text'), findsNothing);
    expect(find.byTooltip('Accessibility settings'), findsOneWidget);
    expect(find.text('PROTOTYPE'), findsNothing);
    expect(find.text('PRODUCTION'), findsNothing);
    expect(find.text('PILOT DATABASE'), findsNothing);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.remove), findsOneWidget);
    expect(find.byIcon(Icons.my_location), findsOneWidget);
    expect(find.text('Map key'), findsOneWidget);
    expect(find.textContaining('Schools ('), findsOneWidget);
    expect(find.textContaining('Sidewalks ('), findsOneWidget);
    expect(find.textContaining('Crossings ('), findsOneWidget);
    expect(find.textContaining('Bike paths ('), findsOneWidget);
    expect(find.textContaining('Bike lanes ('), findsOneWidget);
    expect(find.textContaining('Hazards ('), findsOneWidget);
    expect(find.byKey(const ValueKey('sidewalk-layer')), findsOneWidget);
    expect(find.byKey(const ValueKey('bike-path-layer')), findsOneWidget);
    expect(find.byKey(const ValueKey('layer-crossings')), findsOneWidget);
  });

  testWidgets('Explore remains usable on mobile with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(
      const SafeRoutesApp(
        enableMapTiles: false,
        persistAccessibilityPreferences: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search schools and communities'), findsOneWidget);
    expect(find.text('Map information in text'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Map accepts keyboard zoom controls', (tester) async {
    await tester.pumpWidget(
      const SafeRoutesApp(
        enableMapTiles: false,
        persistAccessibilityPreferences: false,
      ),
    );
    await tester.tap(find.byTooltip('Accessibility settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keyboard map navigation'));
    await tester.tap(find.text('Save choices'));
    await tester.pumpAndSettle();

    final map = find.byType(FlutterMap);
    await tester.ensureVisible(map);
    await tester.pumpAndSettle();
    await tester.tap(map);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('Accessibility choices independently enable map text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SafeRoutesApp(
        enableMapTiles: false,
        persistAccessibilityPreferences: false,
      ),
    );

    expect(find.text('Map information in text'), findsNothing);
    await tester.tap(find.byTooltip('Accessibility settings'));
    await tester.pumpAndSettle();

    expect(find.text('Accessibility settings'), findsOneWidget);
    expect(find.text('Larger text'), findsOneWidget);
    expect(find.text('Higher contrast colors'), findsOneWidget);
    expect(find.text('Larger controls'), findsOneWidget);
    expect(find.text('Keyboard map navigation'), findsOneWidget);
    expect(find.text('Show map information as text'), findsOneWidget);

    await tester.ensureVisible(find.text('Show map information as text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show map information as text'));
    await tester.tap(find.text('Save choices'));
    await tester.pumpAndSettle();

    expect(find.text('Map information in text'), findsOneWidget);
  });

  testWidgets('Reports tab has no fabricated hazard data', (tester) async {
    await tester.pumpWidget(
      const SafeRoutesApp(
        enableMapTiles: false,
        persistAccessibilityPreferences: false,
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byIcon(Icons.list_alt_outlined),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Prioritize community concerns'), findsOneWidget);
    expect(find.text('How the 100-point score is calculated'), findsOneWidget);
    expect(find.text('Connect Supabase to load reports'), findsNWidgets(2));
    expect(find.text('Missing sidewalk'), findsNothing);
  });

  testWidgets('Analytics is a separate tab and never fabricates data', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SafeRoutesApp(
        enableMapTiles: false,
        persistAccessibilityPreferences: false,
      ),
    );
    await tester.tap(find.byIcon(Icons.analytics_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Hazard analytics'), findsOneWidget);
    expect(
      find.text(
        'Supabase is not configured. Analytics never substitutes placeholder data.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Map tap is retained when switching straight to Report tab', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SafeRoutesApp(
        enableMapTiles: false,
        persistAccessibilityPreferences: false,
      ),
    );

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

  testWidgets('Report submission requires a selected map location', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SafeRoutesApp(
        enableMapTiles: false,
        persistAccessibilityPreferences: false,
      ),
    );
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    expect(find.text('Select a point on the map first'), findsOneWidget);
    // The save button is farther down a lazily built scrolling form.
    // A separate form test verifies successful submission with coordinates.
  });
}
