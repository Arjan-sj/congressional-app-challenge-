import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/services/address_search_service.dart';

void main() {
  test('short inputs do not call the server', () async {
    var calls = 0;
    final service = AddressSearchService((_) async { calls++; return {}; });
    expect(await service.search(' ab '), isEmpty);
    expect(calls, 0);
  });
  test('selected nationwide address has validated coordinates', () async {
    final service = AddressSearchService((query) async {
      expect(query, '1600 Pennsylvania Ave');
      return {'suggestions': [
        {'label': '1600 Pennsylvania Ave NW, Washington, DC', 'latitude': 38.8977, 'longitude': -77.0365},
      ]};
    });
    final results = await service.search(' 1600 Pennsylvania Ave ');
    expect(results.single.location.latitude, 38.8977);
    expect(results.single.location.longitude, -77.0365);
  });
  test('empty results are distinct from errors', () async {
    expect(await AddressSearchService((_) async => {'suggestions': []}).search('unfindable address'), isEmpty);
    await expectLater(AddressSearchService((_) async => {}).search('123 Main'), throwsA(isA<AddressSearchException>()));
  });
  test('invalid coordinates and provider errors fail safely', () async {
    final service = AddressSearchService((_) async => {'suggestions': [
      {'label': 'Invalid', 'latitude': 999, 'longitude': -77},
    ]});
    await expectLater(service.search('123 Main'), throwsA(isA<AddressSearchException>()));
    await expectLater(AddressSearchService((_) async => throw Exception('private provider error')).search('123 Main'),
      throwsA(isA<AddressSearchException>().having((e) => e.message, 'sanitized error', isNot(contains('private')))));
  });
}
