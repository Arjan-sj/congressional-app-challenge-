import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AddressSuggestion {
  const AddressSuggestion(this.label, this.location);
  final String label;
  final LatLng location;
}

class AddressSearchException implements Exception {
  const AddressSearchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Addresses travel only through the server proxy, never a keyed browser URL.
class AddressSearchService {
  const AddressSearchService(this.request);
  factory AddressSearchService.supabase(SupabaseClient client) =>
      AddressSearchService((query) async {
        try {
          return (await client.functions.invoke(
            'address-search', body: {'query': query},
          )).data;
        } on FunctionException catch (error) {
          throw AddressSearchException(error.status == 429
              ? 'Address search limit reached. Try later or select a map point.'
              : 'Address search unavailable. Retry or select a map point.');
        }
      });

  final Future<dynamic> Function(String) request;

  Future<List<AddressSuggestion>> search(String input) async {
    final query = input.trim();
    if (query.length < 3) return const [];
    if (query.length > 200) {
      throw const AddressSearchException('Enter an address of at most 200 characters.');
    }
    try {
      final response = await request(query).timeout(const Duration(seconds: 12));
      if (response is! Map || response['suggestions'] is! List) {
        throw const FormatException('Invalid suggestions');
      }
      return (response['suggestions'] as List).take(5).map((row) {
        if (row is! Map || row['label'] is! String ||
            (row['label'] as String).trim().isEmpty ||
            row['latitude'] is! num || row['longitude'] is! num) {
          throw const FormatException('Invalid address');
        }
        final lat = (row['latitude'] as num).toDouble();
        final lon = (row['longitude'] as num).toDouble();
        if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
          throw const FormatException('Invalid address coordinates');
        }
        return AddressSuggestion(row['label'] as String, LatLng(lat, lon));
      }).toList(growable: false);
    } on AddressSearchException {
      rethrow;
    } catch (_) {
      throw const AddressSearchException('Address search unavailable. Retry or select a map point.');
    }
  }
}
