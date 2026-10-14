import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/moviebox/client.dart';
import 'details.dart';
import 'widgets/poster_card.dart';

/// Home: the rails MovieBox returns for one tab.
///
/// The rails come from the API rather than being invented here -- their titles
/// ("Trending", "Latest", ...) are the service's own words. A rail with no
/// titles is dropped by the client, so an empty heading cannot reach this page.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<List<KinoRail>> _rails;

  @override
  void initState() {
    super.initState();
    _rails = context.read<MovieBoxClient>().home();
  }

  Future<void> _reload() async {
    setState(() {
      _rails = context.read<MovieBoxClient>().home();
    });
    await _rails;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<List<KinoRail>>(
          future: _rails,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return _Failure(
                error: snapshot.error!,
                onRetry: _reload,
              );
            }

            final rails = snapshot.data ?? const <KinoRail>[];
            if (rails.isEmpty) {
              return _Failure(
                error: const MovieBoxException(
                  'The API authenticated but returned no rails. That means the '
                  'response shape changed rather than that there is no content.',
                ),
                onRetry: _reload,
              );
            }

            return RefreshIndicator(
              onRefresh: _reload,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      child: Text('kino', style: text.displaySmall),
                    ),
                  ),
                  for (final rail in rails)
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
                            child: Text(
                              rail.title,
                              style: text.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 230,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              itemCount: rail.items.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 12),
                              itemBuilder: (context, index) {
                                final item = rail.items[index];
                                return PosterCard(
                                  item: item,
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => DetailsPage(item: item),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 32 + MediaQuery.of(context).padding.bottom,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      // The error colours are read here rather than in _Failure so the failure
      // widget stays a plain widget with no theme dependency of its own.
      backgroundColor: scheme.surface,
    );
  }
}

/// A failure, with the actual error text.
///
/// Deliberately shows the raw message rather than a friendly one. Every failure
/// in this app so far has been a shape mismatch -- a key that moved, a type that
/// differed -- and "something went wrong" would hide the only useful part.
class _Failure extends StatelessWidget {
  final Object error;
  final Future<void> Function() onRetry;

  const _Failure({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        Icon(Icons.cloud_off, size: 48, color: scheme.error),
        const SizedBox(height: 16),
        Text('Could not load', style: text.titleMedium),
        const SizedBox(height: 12),
        SelectableText(
          '$error',
          style: text.bodySmall?.copyWith(
            fontFamily: 'monospace',
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.tonal(
          onPressed: onRetry,
          child: const Text('Try again'),
        ),
      ],
    );
  }
}