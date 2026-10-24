import 'package:congressional_app/models/school_district.dart';
import 'package:congressional_app/screens/analytics_district_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<AnalyticsDistrictOption> districts(int count) => [
  for (var i = 0; i < count; i++)
    AnalyticsDistrictOption(
      id: 'nces-lea:${1000000 + i}',
      name: i >= count - 2 ? 'Union School District' : 'District $i',
      state: 'DE',
    ),
];

Widget harness({
  required List<AnalyticsDistrictOption> options,
  required ValueChanged<Set<String>?> onResult,
  Set<String> selected = const {},
  double textScale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () async => onResult(
            await showDialog<Set<String>>(
              context: context,
              builder: (_) => AnalyticsDistrictPicker(
                districts: options,
                selected: selected,
              ),
            ),
          ),
          child: const Text('Open districts'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'large directory builds visible rows only and preserves duplicate-name IDs',
    (tester) async {
      const count = 19636;
      final options = districts(count);
      Set<String>? result;
      await tester.pumpWidget(
        harness(options: options, onResult: (value) => result = value),
      );
      await tester.tap(find.text('Open districts'));
      await tester.pumpAndSettle();

      expect(find.byType(CheckboxListTile).evaluate().length, lessThan(50));
      expect(find.text('0 selected · $count matches'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'UNION');
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      expect(find.text(options[count - 2].displayLabel), findsOneWidget);
      expect(find.text(options.last.displayLabel), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('district-${options.last.id}')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '1019635');
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(result, {options.last.id});
    },
  );

  testWidgets('Clear returns an empty filter and an unmatched query is clear', (
    tester,
  ) async {
    final options = districts(3);
    Set<String>? result;
    await tester.pumpWidget(
      harness(
        options: options,
        selected: {options.first.id},
        onResult: (value) => result = value,
      ),
    );
    await tester.tap(find.text('Open districts'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'no matching district');
    await tester.pumpAndSettle();
    expect(find.text('No districts match.'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(result, isEmpty);
  });

  testWidgets(
    'district selection remains reachable on narrow screens with enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final options = districts(19636);
      Set<String>? result;
      await tester.pumpWidget(
        harness(
          options: options,
          textScale: 1.6,
          onResult: (value) => result = value,
        ),
      );
      await tester.tap(find.text('Open districts'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), options.last.id);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(result, {options.last.id});
      expect(tester.takeException(), isNull);
    },
  );
}
