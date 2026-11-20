import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'blast_wav.dart';

/// Synthesised arcade sounds for the desktop build. A small pool of
/// players lets a shot, an explosion and a wave cue overlap cleanly.
class BlastSound {
  final List<AudioPlayer> _players = [
    for (var i = 0; i < 4; i++) AudioPlayer(),
  ];
  int _next = 0;
  bool muted = false;

  void unlock() {} // no browser gesture gate on desktop

  void play(String effect) {
    if (muted) return;
    final player = _players[_next = (_next + 1) % _players.length];
    try {
      unawaited(player.play(BytesSource(blastWav(effect))).catchError((_) {}));
    } catch (_) {
      // No audio device in a test/headless run must never break the game.
    }
  }

  Future<void> dispose() async {
    for (final p in _players) {
      await p.dispose();
    }
  }
}
