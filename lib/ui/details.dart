import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/moviebox/client.dart';
import 'player.dart';
import 'watchlist.dart';

/// Details for one title, and its Play button.
///
/// Two different flows, decided by `subjectType`:
///
///   * **A film** — one Play button, `subjectId` alone, no season or episode.
///   * **A series** — a season picker, then episode rows.
///
/// The seasons come from `season-info`, whose envelope was **not** measured --
/// only search and home were. So [MovieBoxClient.seasonsOf] reads several
/// plausible keys and returns an empty list rather than throwing. A series page
/// without its episode list still shows its poster, synopsis and a Play button
/// that tries the film path; a crash would lose all of that.
class DetailsPage extends StatefulWidget {
  /// The item tapped, so the page renders its poster and title immediately
  /// instead of showing a spinner over an empty screen.
  final KinoItem item;

  const DetailsPage({super.key, required this.item});

  @override
  State<DetailsPage> createState() => _DetailsPageState();
}

class _DetailsPageState extends State<DetailsPage> {
  late Future<Map<String, dynamic>> _details;

  KinoSeason? _selectedSeason;

  @override
  void initState() {
    super.initState();
    _details = context.read<MovieBoxClient>().details(widget.item.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // Watched rather than read, so the bookmark icon reflects the current state
    // on every rebuild -- including right after a toggle.
    final watchlist = context.watch<Watchlist>();
    final saved = watchlist.contains(widget.item.id);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => watchlist.toggle(widget.item),
        icon: Icon(saved ? Icons.bookmark : Icons.bookmark_outline),
        label: Text(saved ? 'Saved' : 'Save'),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _details,
        builder: (context, snapshot) {
          final details = snapshot.data;
          final seasons = details == null
              ? const <KinoSeason>[]
              : MovieBoxClient.seasonsOf(details);

          // Default to the first season once, so the picker is not empty on
          // arrival. Guarded by `_selectedSeason == null` so a user's choice is
          // not overwritten by a rebuild.
          if (_selectedSeason == null && seasons.isNotEmpty) {
            _selectedSeason = seasons.first;
          }

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 300,
                pinned: true,
                flexibleSpace: FlexibleSpaceBar(
                  background: _poster(),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.item.title, style: text.headlineSmall),
                      const SizedBox(height: 6),
                      if (widget.item.year != null ||
                          widget.item.rating != null)
                        Text(
                          [
                            if (widget.item.year != null) widget.item.year!,
                            if (widget.item.rating != null)
                              '${widget.item.rating!.toStringAsFixed(1)} / 10',
                          ].join('  ·  '),
                          style: text.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      const SizedBox(height: 16),
                      _actions(details, seasons),
                    ],
                  ),
                ),
              ),
              if (snapshot.connectionState == ConnectionState.waiting)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              if (snapshot.hasError)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: SelectableText(
                      '${snapshot.error}',
                      style: text.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: scheme.error,
                      ),
                    ),
                  ),
                ),
              if (details != null) ...[
                SliverToBoxAdapter(child: _overview(details, text, scheme)),
                if (seasons.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _seasonPicker(seasons, scheme),
                  ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          );
        },
      ),
      backgroundColor: scheme.surface,
    );
  }

  Widget _poster() {
    final poster = widget.item.poster;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (poster != null && poster.isNotEmpty)
          CachedNetworkImage(
            imageUrl: poster,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          )
        else
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        // A scrim, so the app bar's back button stays visible over a bright
        // poster. Without it a light artwork makes the control disappear.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Color(0x00000000)],
              stops: [0, 1],
            ),
          ),
        ),
      ],
    );
  }

  Widget _actions(Map<String, dynamic>? details, List<KinoSeason> seasons) {
    final season = _selectedSeason;

    return Row(
      children: [
        FilledButton.icon(
          onPressed: details == null ? null : () => _play(season),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Play'),
        ),
        if (seasons.isNotEmpty) ...[
          const SizedBox(width: 12),
          Text(
            '${seasons.length} season${seasons.length == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _overview(
    Map<String, dynamic> details,
    TextTheme text,
    ColorScheme scheme,
  ) {
    final description = details['description'] ?? details['synopsis'];
    if (description is! String || description.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Overview', style: text.titleMedium),
          const SizedBox(height: 8),
          Text(
            description,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _seasonPicker(List<KinoSeason> seasons, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Seasons', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final season in seasons)
                ChoiceChip(
                  label: Text(
                    season.episodeCount > 0
                        ? 'Season ${season.season} · ${season.episodeCount}'
                        : 'Season ${season.season}',
                  ),
                  selected: _selectedSeason?.season == season.season,
                  onSelected: (_) =>
                      setState(() => _selectedSeason = season),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _play(KinoSeason? season) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          title: widget.item.title,
          subjectId: widget.item.id,
          // 0/0 is the film path: the client leaves season and episode off the
          // query entirely, which is what the API expects for a movie.
          season: season?.season ?? 0,
          episode: season == null ? 0 : 1,
        ),
      ),
    );
  }
}