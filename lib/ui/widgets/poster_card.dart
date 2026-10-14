import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/moviebox/client.dart';

/// One poster tile.
///
/// Shared by Home, Search and the details page's related rows, so the three
/// cannot drift apart in size or fallback behaviour.
///
/// The fallback matters more than usual here: `poster` comes from an object
/// nested three levels into the response (`cover.url`), so if a field name is
/// ever wrong every card goes grey rather than throwing. A visible placeholder
/// is the honest failure.
class PosterCard extends StatelessWidget {
  final KinoItem item;
  final VoidCallback onTap;

  /// Home rails are horizontal and dense; the grid is wider. One flag rather
  /// than two widgets, because everything else about the tile is identical.
  final bool compact;

  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.compact = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return SizedBox(
      width: compact ? 120 : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: item.poster == null || item.poster!.isEmpty
                    ? Container(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.movie_outlined,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: item.poster!,
                        fit: BoxFit.cover,
                        // Both handlers show something rather than an empty box:
                        // a broken URL should still leave a tappable tile, or a
                        // row of them silently becomes a gap.
                        placeholder: (_, __) =>
                            Container(color: scheme.surfaceContainerHighest),
                        errorWidget: (_, __, ___) => Container(
                          color: scheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(fontWeight: FontWeight.w500),
            ),
            if (item.year != null || item.rating != null)
              Text(
                [
                  if (item.year != null) item.year!,
                  if (item.rating != null) item.rating!.toStringAsFixed(1),
                ].join(' · '),
                maxLines: 1,
                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}