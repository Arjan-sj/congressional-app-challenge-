import 'package:flutter/material.dart';

class HazardPhotoView extends StatelessWidget {
  const HazardPhotoView({super.key, required this.url, this.height = 220});

  final String url;
  final double height;

  void _showFullScreen(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: .8,
                  maxScale: 5,
                  child: Center(
                    child: Image.network(
                      url,
                      fit: BoxFit.contain,
                      semanticLabel: 'Full-screen hazard photo evidence',
                      errorBuilder: (_, _, _) => const _PhotoError(),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton.filled(
                  tooltip: 'Close photo',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Hazard photo evidence. Open full-screen preview.',
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showFullScreen(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              SizedBox(
                width: double.infinity,
                height: height,
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  semanticLabel: 'Hazard photo evidence',
                  errorBuilder: (_, _, _) => const _PhotoError(),
                  loadingBuilder: (context, child, loadingProgress) =>
                      loadingProgress == null
                      ? child
                      : const ColoredBox(
                          color: Color(0xFFE7E9E8),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(10),
                child: Chip(
                  avatar: Icon(Icons.fullscreen, size: 18),
                  label: Text('Open photo'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoError extends StatelessWidget {
  const _PhotoError();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('Photo evidence is temporarily unavailable.'),
      ),
    ),
  );
}
