import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/app.dart';

void main() {
  testWidgets('SafeRoutes shows an honest prototype map placeholder', (tester) async {
    await tester.pumpWidget(const SafeRoutesApp());

    expect(find.text('SafeRoutes'), findsOneWidget);
    expect(find.text('School area map'), findsOneWidget);
    expect(find.text('PROTOTYPE'), findsOneWidget);
  });

  testWidgets('Reports tab shows fictional sample records', (tester) async {
    await tester.pumpWidget(const SafeRoutesApp());
    await tester.tap(find.byIcon(Icons.list_alt_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Example reports'), findsOneWidget);
    expect(find.text('Missing sidewalk'), findsOneWidget);
  });
}
