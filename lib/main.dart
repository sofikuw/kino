import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'core/moviebox/client.dart';
import 'ui/home.dart';
import 'ui/search.dart';
import 'ui/watchlist.dart';

void main() {
  // MUST come before any Player is constructed. media_kit needs its native
  // bindings registered, and a Player built without this throws on the first
  // `open()` rather than at the point of the mistake -- which reads as "the
  // stream is broken" instead of "the player was never initialised".
  MediaKit.ensureInitialized();

  runApp(const KinoApp());
}

/// kino.
///
/// Material 3 throughout: one seed colour drives both schemes, nothing below
/// hardcodes a colour, and the components are M3 (`NavigationBar`, `SearchBar`,
/// `FilledButton`, `ChoiceChip`).
class KinoApp extends StatelessWidget {
  const KinoApp({super.key});

  /// Seed for the colour scheme. A purple that reads as "cinema" without being
  /// a brand colour; every surface in the app is derived from it.
  static const Color seed = Color(0xFF6C5CE7);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<MovieBoxClient>(
          // One client for the whole app, so the visitor token and the chosen
          // host are shared rather than re-established per screen.
          create: (_) => MovieBoxClient(),
          dispose: (_, client) => client.close(),
        ),
        ChangeNotifierProvider<Watchlist>(create: (_) => Watchlist()..load()),
      ],
      child: MaterialApp(
        title: 'kino',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: seed,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const RootScaffold(),
      ),
    );
  }
}

/// The three destinations.
class RootScaffold extends StatefulWidget {
  const RootScaffold({super.key});

  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold> {
  int _index = 0;

  static const List<Widget> _pages = [
    HomePage(),
    SearchPage(),
    WatchlistPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack rather than swapping the child: home rails and search
      // results survive a tab switch. A rebuilt subtree loses them, and the user
      // sees a spinner where their results were.
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.movie_outlined),
            selectedIcon: Icon(Icons.movie),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: 'Search',
          ),
          NavigationDestination(
            icon: Icon(Icons.bookmark_outline),
            selectedIcon: Icon(Icons.bookmark),
            label: 'Watchlist',
          ),
        ],
      ),
    );
  }
}