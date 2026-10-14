import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/moviebox/client.dart';
import 'details.dart';
import 'widgets/poster_card.dart';

/// A local watchlist.
///
/// `shared_preferences` rather than a database: this is a list of ids and titles
/// for one person on one device, and the app has no account system of its own.
/// The token it holds for MovieBox is a *visitor* token, shared by nobody and
/// identifying no one, so there is no server-side list to sync with.
///
/// Stored as JSON under one key rather than as many keys. One key means one
/// write per change and no chance of a half-updated list; the cost is rewriting
/// the whole list, which for a few hundred titles is nothing.
class Watchlist extends ChangeNotifier {
  static const String _key = 'kino.watchlist';

  /// Mutable, and `const []` here would be a runtime crash on the first
  /// `add` -- a `const` list is unmodifiable. Declared empty, not const.
  final List<KinoItem> _items = <KinoItem>[];

  bool _loaded = false;

  List<KinoItem> get items => List.unmodifiable(_items);
  bool get isLoaded => _loaded;
  bool get isEmpty => _items.isEmpty;

  bool contains(String id) => _items.any((item) => item.id == id);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      _items.clear();

      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is! Map) continue;
            // Rebuilt through the same parser the API responses use, so a stored
            // item and a fetched one cannot drift in shape.
            _items.add(KinoItem(
              id: entry['id']?.toString() ?? '',
              title: entry['title']?.toString() ?? '',
              poster: entry['poster']?.toString(),
              year: entry['year']?.toString(),
              rating: (entry['rating'] as num?)?.toDouble(),
              subjectType: (entry['subjectType'] as num?)?.toInt() ?? 1,
            ));
          }
        }
      }
    } catch (_) {
      // A corrupt store costs the watchlist, not the app. Cleared so the next
      // write starts from a clean list rather than failing forever.
      _items.clear();
    }

    _loaded = true;
    notifyListeners();
  }

  Future<void> toggle(KinoItem item) async {
    if (contains(item.id)) {
      _items.removeWhere((existing) => existing.id == item.id);
    } else {
      _items.insert(0, item);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode([
          for (final item in _items)
            {
              'id': item.id,
              'title': item.title,
              'poster': item.poster,
              'year': item.year,
              'rating': item.rating,
              'subjectType': item.subjectType,
            },
        ]),
      );
    } catch (_) {
      // A failed write is reported by the list reverting on next launch rather
      // than by an error the user cannot act on.
    }
  }
}

/// The watchlist tab.
class WatchlistPage extends StatelessWidget {
  const WatchlistPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Consumer<Watchlist>(
          builder: (context, watchlist, _) {
            if (!watchlist.isLoaded) {
              return const Center(child: CircularProgressIndicator());
            }

            if (watchlist.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.bookmark_outline,
                        size: 48,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Nothing saved yet.',
                        style: text.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Open a title and tap the bookmark to keep it here.',
                        textAlign: TextAlign.center,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                    child: Text('Watchlist', style: text.displaySmall),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverGrid.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 140,
                      childAspectRatio: 0.55,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 16,
                    ),
                    itemCount: watchlist.items.length,
                    itemBuilder: (context, index) {
                      final item = watchlist.items[index];
                      return PosterCard(
                        item: item,
                        compact: false,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DetailsPage(item: item),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
            );
          },
        ),
      ),
      backgroundColor: scheme.surface,
    );
  }
}