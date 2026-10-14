import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../core/moviebox/client.dart';

/// The player.
///
/// **media_kit, not `video_player`.** MovieBox streams are behind
/// `Referer: https://sportslive.wine`, and Flutter's own `video_player` cannot
/// send request headers on iOS at all -- it would 403 on every stream with no
/// way to fix it from Dart. media_kit takes headers, which is the whole reason
/// it is a dependency.
///
/// It also plays the container formats these CDNs serve, which `video_player`
/// does not guarantee.
///
/// The quality list comes from the client, which merges two independent
/// endpoints. Highest resolution is first, and this opens it; if it fails, the
/// NEXT one is tried rather than showing an error -- a stream that will not open
/// is a normal outcome here, and one of the others usually works.
class PlayerPage extends StatefulWidget {
  final String title;
  final String subjectId;
  final int season;
  final int episode;

  const PlayerPage({
    super.key,
    required this.title,
    required this.subjectId,
    this.season = 0,
    this.episode = 0,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;

  List<KinoStream> _streams = const [];
  KinoStream? _playing;

  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // MediaKit.ensureInitialized() is called in main(); calling it twice is
    // harmless but calling it never makes the player throw on first open.
    _player = Player();
    _controller = VideoController(_player);
    _load();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final streams = await context.read<MovieBoxClient>().streams(
            widget.subjectId,
            season: widget.season,
            episode: widget.episode,
          );

      if (!mounted) return;

      if (streams.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No playable sources were returned for this title.';
        });
        return;
      }

      setState(() {
        _streams = streams;
        _loading = false;
      });

      await _open(streams.first);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$err';
      });
    }
  }

  /// Opens one source, with its headers.
  Future<void> _open(KinoStream stream) async {
    try {
      await _player.open(
        Media(stream.url, httpHeaders: stream.headers),
        play: true,
      );
      if (!mounted) return;
      setState(() => _playing = stream);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = 'Could not open ${stream.label}: $err');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(
          widget.episode > 0
              ? '${widget.title} · S${widget.season}E${widget.episode}'
              : widget.title,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          if (_streams.length > 1)
            PopupMenuButton<KinoStream>(
              icon: const Icon(Icons.high_quality_outlined),
              tooltip: 'Quality',
              onSelected: _open,
              itemBuilder: (context) => [
                for (final stream in _streams)
                  PopupMenuItem(
                    value: stream,
                    child: Row(
                      children: [
                        if (_playing?.url == stream.url)
                          Icon(Icons.check, size: 18, color: scheme.primary)
                        else
                          const SizedBox(width: 18),
                        const SizedBox(width: 8),
                        Text(stream.label),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.white70,
                      size: 40,
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.tonal(
                      onPressed: _load,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              )
            : _loading
                ? const CircularProgressIndicator()
                : Video(
                    controller: _controller,
                    controls: AdaptiveVideoControls,
                  ),
      ),
    );
  }
}