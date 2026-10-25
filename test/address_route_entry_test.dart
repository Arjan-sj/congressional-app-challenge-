import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:congressional_app/services/address_search_service.dart';
import 'package:congressional_app/widgets/address_route_entry.dart';

void main() {
  testWidgets('debounces typing and selecting an address submits coordinates', (tester) async {
    var calls = 0;
    String? selected;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AddressRouteEntry(
      label: 'Start location', onSet: (value) async { selected = value; return null; },
      search: (_) async { calls++; return [const AddressSuggestion('123 Main St, Boston, MA', LatLng(42.3, -71.1))]; },
    ))));
    await tester.enterText(find.byType(TextField), '123');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField), '123 Main');
    await tester.pump(const Duration(milliseconds: 449));
    expect(calls, 0);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(calls, 1);
    await tester.tap(find.text('123 Main St, Boston, MA'));
    await tester.pump();
    expect(selected, '42.3, -71.1');
  });

  testWidgets('stale results cannot replace a newer query; empty and error states render', (tester) async {
    final old = Completer<List<AddressSuggestion>>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AddressRouteEntry(
      label: 'End location', onSet: (_) async => null,
      search: (query) => query == 'old address' ? old.future
          : query == 'error address' ? Future.error(const AddressSearchException('Search limit reached'))
          : Future.value([]),
    ))));
    await tester.enterText(find.byType(TextField), 'old address');
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'new address');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    old.complete([const AddressSuggestion('Stale address', LatLng(40, -80))]);
    await tester.pump();
    expect(find.text('Stale address'), findsNothing);
    expect(find.textContaining('No addresses found'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'error address');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.text('Search limit reached'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('map selection updates text and cancels in-flight autocomplete', (tester) async {
    final pending = Completer<List<AddressSuggestion>>();
    Future<void> show(LatLng? point) => tester.pumpWidget(MaterialApp(home: Scaffold(body: AddressRouteEntry(
      label: 'Start location', point: point, onSet: (_) async => null, search: (_) => pending.future,
    ))));
    await show(null);
    await tester.enterText(find.byType(TextField), '123 Main');
    await tester.pump(const Duration(milliseconds: 450));
    await show(const LatLng(41, -87));
    pending.complete([const AddressSuggestion('Old result', LatLng(40, -80))]);
    await tester.pump();
    expect(find.text('Old result'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '41.0, -87.0');
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('pasting a replacement address clears the endpoint and still searches', (tester) async {
    LatLng? point = const LatLng(41, -87);
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, setState) => AddressRouteEntry(
        label: 'Start location', point: point, onSet: (_) async => null,
        onEdited: () => setState(() => point = null),
        search: (_) async { calls++; return []; },
      ),
    ))));
    await tester.enterText(find.byType(TextField), '123 Replacement St');
    await tester.pump();
    expect(point, isNull);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(calls, 1);
    expect(find.textContaining('No addresses found'), findsOneWidget);
  });
}
