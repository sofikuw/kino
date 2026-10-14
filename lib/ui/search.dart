import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/moviebox/client.dart';
import 'details.dart';
import 'widgets/poster_card.dart';

/// Search, built on Material 3's `SearchAnchor`.
///
/// **Debounced, and that is not an optimisation.** The API is a JSON POST with a
/// signed request and a bearer token, and it holds a 15-per-page query open on
/// their side. Firing one per keystroke would send eight requests for "naruto"
/// and the last one to *arrive* would win, which is not necessarily the last one
/// sent -- so results could show "nar" while the field says "naruto".
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final SearchController _controller = SearchController();

  Timer? _debounce;

  /// Guards against out-of-order responses. The counter is incremented per
  /// request and captured in the closure; a reply whose sequence is not the
  /// latest is discarded rather than rendered.
  int _sequence = 0;

  bool _searching = false;
  String? _error;
  List<KinoItem> _results = const [];

  /// The query the current results belong to, so an empty grid can say which
  /// term found nothing.
  String _lastQuery = '';

  static const Duration _debounceDelay = Duration(milliseconds: 400);

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String query) {
    _debounce?.cancel();

    if (query.trim().isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
        _searching = false;
        _lastQuery = '';
      });
      return;
    }

    // The timer restarts on every keystroke, so the request only goes out once
    // typing pauses.
    _debounce = Timer(_debounceDelay, () => _run(query));
  }

  Future<void> _run(String query) async {
    final mine = ++_sequence;
    setState(() {
      _searching = true;
      _error = null;
    });

    try {
      final items = await context.read<MovieBoxClient>().search(query);
      if (!mounted || mine != _sequence) return;
      setState(() {
        _results = items;
        _searching = false;
        _lastQuery = query;
      });
    } catch (err) {
      if (!mounted || mine != _sequence) return;
      setState(() {
        _error = err.toString();
        _searching = false;
        _lastQuery = query;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: SearchAnchor(
          searchController: _controller,
          builder: (context, controller) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: SearchBar(
                controller: controller,
                hintText: 'Search movies and shows',
                leading: const Icon(Icons.search),
                onTap: () => controller.openView(),
                onChanged: (_) => controller.openView(),
              ),
            );
          },
          suggestionsBuilder: (context, controller) {
            // The view rebuilds on every keystroke, so the debounce is armed
            // here rather than in a TextField callback -- SearchAnchor owns the
            // field.
            _onChanged(controller.text);
            return <Widget>[
              Padding(
                padding: const EdgeInsets.all(20),
                child: _resultsBody(scheme, text),
              ),
            ];
          },
        ),
      ),
      backgroundColor: scheme.surface,
    );
  }

  Widget _resultsBody(ColorScheme scheme, TextTheme text) {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_off, color: scheme.error),
          const SizedBox(height: 12),
          SelectableText(
            _error!,
            style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      );
    }

    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            _lastQuery.isEmpty
                ? 'Type to search.'
                : 'Nothing found for "$_lastQuery".',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        // Max extent rather than a fixed column count: the same grid then works
        // on a phone and an iPad without a breakpoint.
        maxCrossAxisExtent: 140,
        childAspectRatio: 0.55,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final item = _results[index];
        return PosterCard(
          item: item,
          compact: false,
          onTap: () {
            _controller.closeView(null);
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => DetailsPage(item: item)),
            );
          },
        );
      },
    );
  }
}