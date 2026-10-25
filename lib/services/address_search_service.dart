import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AddressSuggestion {
  const AddressSuggestion(this.label, this.location);
  final String label;
  final LatLng location;
}

class AddressSearchException implements Exception {
  const AddressSearchException(this.message, {this.retryAfter});
  final String message;
  final Duration? retryAfter;
  @override
  String toString() => message;
}

/// Addresses travel only through the server proxy, never a keyed browser URL.
class AddressSearchService {
  AddressSearchService(this.request, {DateTime Function()? now}) : _now = now ?? DateTime.now;
  factory AddressSearchService.supabase(SupabaseClient client) =>
      AddressSearchService((query) async {
        try {
          return (await client.functions.invoke(
            'address-search', body: {'query': query},
          )).data;
        } on FunctionException catch (error) {
          if (error.status == 429) {
            final details = error.details;
            final seconds = details is Map && details['retry_after'] is num
                ? (details['retry_after'] as num).toInt().clamp(1, 86400) : 60;
            throw AddressSearchException('Search is cooling down. Retrying automatically.',
                retryAfter: Duration(seconds: seconds));
          }
          throw const AddressSearchException('Address search unavailable. Retry or select a map point.');
        }
      });

  final Future<dynamic> Function(String) request;
  final DateTime Function() _now;
  final _cache = <String, ({DateTime expires, List<AddressSuggestion> results})>{};
  final _pending = <String, Future<List<AddressSuggestion>>>{};
  DateTime? _retryAt;

  Future<List<AddressSuggestion>> search(String input) async {
    final query = input.trim();
    if (query.length < 3) return const [];
    if (query.length > 200) {
      throw const AddressSearchException('Enter an address of at most 200 characters.');
    }
    final key = query.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final cached = _cache[key];
    if (cached != null && cached.expires.isAfter(_now())) return cached.results;
    final retryAt = _retryAt;
    if (retryAt != null && retryAt.isAfter(_now())) {
      throw AddressSearchException('Search is cooling down. Retrying automatically.',
          retryAfter: retryAt.difference(_now()));
    }
    final existing = _pending[key];
    if (existing != null) return existing;
    final work = _load(query);
    _pending[key] = work;
    try {
      final results = await work;
      if (_cache.length >= 24) _cache.remove(_cache.keys.first);
      _cache[key] = (expires: _now().add(const Duration(minutes: 1)), results: results);
      return results;
    } on AddressSearchException catch (error) {
      if (error.retryAfter != null) _retryAt = _now().add(error.retryAfter!);
      rethrow;
    } finally {
      if (identical(_pending[key], work)) _pending.remove(key);
    }
  }

  Future<List<AddressSuggestion>> _load(String query) async {
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
