import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../services/address_search_service.dart';

class AddressRouteEntry extends StatefulWidget {
  const AddressRouteEntry({super.key, required this.label, required this.onSet,
    this.search, this.point, this.onEdited});
  final String label;
  final Future<String?> Function(String) onSet;
  final Future<List<AddressSuggestion>> Function(String)? search;
  final LatLng? point;
  final VoidCallback? onEdited;
  @override
  State<AddressRouteEntry> createState() => _AddressRouteEntryState();
}

class _AddressRouteEntryState extends State<AddressRouteEntry> {
  final controller = TextEditingController();
  Timer? debounce;
  int version = 0;
  bool busy = false;
  bool editing = false;
  String? message;
  List<AddressSuggestion> suggestions = [];
  LatLng? chosen;

  @override
  void initState() {
    super.initState();
    if (widget.point case final point?) {
      controller.text = '${point.latitude}, ${point.longitude}';
    }
  }

  @override
  void didUpdateWidget(covariant AddressRouteEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.point != oldWidget.point) {
      // Editing invalidates the old route point without cancelling this query.
      if (widget.point == null && editing) return;
      debounce?.cancel();
      version++;
      busy = false;
      suggestions = [];
      message = null;
      if (widget.point != null && widget.point != chosen) {
        editing = false;
        controller.text = '${widget.point!.latitude}, ${widget.point!.longitude}';
      } else if (widget.point == null && !editing) {
        controller.clear();
      }
    }
  }

  void changed(String text) {
    debounce?.cancel();
    final current = ++version;
    editing = true;
    chosen = null;
    widget.onEdited?.call();
    setState(() { suggestions = []; message = null; busy = false; });
    if (text.trim().length < 3 || widget.search == null) return;
    debounce = Timer(const Duration(milliseconds: 450), () async {
      if (!mounted || current != version) return;
      setState(() => busy = true);
      try {
        final results = await widget.search!(text);
        if (!mounted || current != version) return;
        setState(() {
          suggestions = results;
          message = results.isEmpty ? 'No addresses found. Include city, state or ZIP, or use the map.' : null;
        });
      } catch (error) {
        if (mounted && current == version) {
          setState(() => message = error is AddressSearchException
              ? error.message : 'Address search unavailable. Retry or use the map.');
        }
      } finally {
        if (mounted && current == version) setState(() => busy = false);
      }
    });
  }

  Future<void> submit([AddressSuggestion? suggestion]) async {
    debounce?.cancel();
    final current = ++version;
    editing = false;
    chosen = suggestion?.location;
    if (suggestion != null) controller.text = suggestion.label;
    setState(() { busy = true; suggestions = []; message = null; });
    try {
      final result = await widget.onSet(suggestion == null
          ? controller.text.trim()
          : '${suggestion.location.latitude}, ${suggestion.location.longitude}');
      if (mounted && (current == version || widget.point == chosen && chosen != null)) {
        setState(() => message = result ?? 'Location selected.');
      }
    } catch (_) {
      if (mounted && current == version) setState(() => message = 'Location lookup unavailable.');
    } finally {
      if (mounted && (current == version || widget.point == chosen && chosen != null)) {
        setState(() => busy = false);
      }
    }
  }

  @override
  void dispose() { debounce?.cancel(); version++; controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(widget.label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(child: TextField(
          key: ValueKey(widget.label == 'Start location' ? 'route-start-entry' : 'route-end-entry'),
          controller: controller,
          maxLength: 200,
          onChanged: changed,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => submit(),
          decoration: InputDecoration(
            hintText: 'Street address, school name or coordinates',
            counterText: '',
            suffixIcon: busy ? const Padding(padding: EdgeInsets.all(14),
              child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))) : null,
          ),
        )),
        const SizedBox(width: 8),
        FilledButton.tonal(onPressed: busy ? null : () => submit(), child: const Text('Set')),
      ]),
      for (final suggestion in suggestions)
        ListTile(title: Text(suggestion.label), leading: const Icon(Icons.place_outlined),
          onTap: () => submit(suggestion)),
      if (suggestions.isNotEmpty)
        const Text('Geocoding: OpenRouteService / Pelias. Data: OpenStreetMap contributors, OpenAddresses, GeoNames, Who’s On First.'),
      if (message != null) Text(message!, semanticsLabel: message),
      if (widget.search == null)
        const Text('Address search unavailable. Use a school name, coordinates or the map.'),
    ],
  );
}
