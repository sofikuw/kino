import 'package:flutter/material.dart';

import 'core/moviebox/client.dart';

void main() {
  runApp(const KinoApp());
}

/// kino -- step one.
///
/// **This app does exactly one thing: it logs in to MovieBox and shows you the
/// result.** No search, no rails, no player, no watchlist. That is deliberate,
/// and it is the whole point of this stage.
///
/// The previous draft of this file imported five screens and a client that
/// never compiled. This one has no unverified surface: the signer behind it was
/// run against the live API from a Val Town script and returned HTTP 200 with a
/// visitor token, so what is on screen is the result of a real signed request.
///
/// If this launches and shows a token expiry, then Material 3 is wired, the
/// network path works, HMAC-MD5 in Dart matches the server, and the region gate
/// is cleared -- four things proved at once, on a device, from one screen.
class KinoApp extends StatelessWidget {
  const KinoApp({super.key});

  @override
  Widget build(BuildContext context) {
    // One seed colour drives both schemes. Nothing below hardcodes a colour,
    // which is the point of M3 and the reason there is no theme file here.
    return MaterialApp(
      title: 'kino',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C5CE7),
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C5CE7),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const LoginProbePage(),
    );
  }
}

/// Logs in and reports what happened.
class LoginProbePage extends StatefulWidget {
  const LoginProbePage({super.key});

  @override
  State<LoginProbePage> createState() => _LoginProbePageState();
}

class _LoginProbePageState extends State<LoginProbePage> {
  final MovieBoxClient _client = MovieBoxClient();

  bool _running = false;
  String? _error;

  /// Never the token itself -- it is a credential and this screen is not a
  /// secure place for one. Only its shape and lifetime are shown, which is
  /// enough to tell a working login from a broken one.
  String? _summary;

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _summary = null;
    });

    try {
      final result = await _client.login();
      if (!mounted) return;
      setState(() {
        _summary = result;
        _running = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.toString();
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Text('kino', style: text.displaySmall),
              const SizedBox(height: 8),
              Text(
                'Step one: prove the MovieBox session works on this device.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: _running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: Text(_running ? 'Signing in…' : 'Sign in to MovieBox'),
              ),
              const SizedBox(height: 24),
              if (_summary != null)
                Card(
                  color: scheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.check_circle,
                              color: scheme.onSecondaryContainer,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Signed in',
                              style: text.titleMedium?.copyWith(
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SelectableText(
                          _summary!,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSecondaryContainer,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_error != null)
                Card(
                  color: scheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.error_outline, color: scheme.onErrorContainer),
                            const SizedBox(width: 8),
                            Text(
                              'Failed',
                              style: text.titleMedium?.copyWith(
                                color: scheme.onErrorContainer,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SelectableText(
                          _error!,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onErrorContainer,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}