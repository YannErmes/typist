import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

/// Synthesised arcade sounds for the Blast game (browser build).
///
/// Web Audio oscillators/buffers give instant, asset-free feedback — no
/// loading wait before the first shot. Browsers only allow audio after a
/// user gesture, so [unlock] is called on the first key/tap.
class BlastSound {
  web.AudioContext? _ctx;
  bool muted = false;

  web.AudioContext? _ensure() {
    if (_ctx != null) return _ctx;
    try {
      _ctx = web.AudioContext();
    } catch (_) {}
    return _ctx;
  }

  void unlock() {
    final ctx = _ensure();
    try {
      ctx?.resume();
    } catch (_) {}
  }

  void dispose() {
    _ctx = null;
    muted = false;
  }

  void play(String effect) {
    if (muted) return;
    final ctx = _ensure();
    if (ctx == null) return;
    try {
      switch (effect) {
        case 'lock':
          _tone(ctx, 880, 0.045, 'square', 0.025);
        case 'shoot':
          _tone(ctx, 320, 0.09, 'sawtooth', 0.05, 70);
          _noise(ctx, 0.05, 0.02);
        case 'explode':
          _noise(ctx, 0.18, 0.06);
          _tone(ctx, 120, 0.18, 'triangle', 0.03, 40);
        case 'miss':
          _tone(ctx, 150, 0.09, 'square', 0.03, 90);
        case 'emp':
          _tone(ctx, 70, 0.55, 'sine', 0.09, 28);
          _tone(ctx, 420, 0.4, 'sawtooth', 0.03, 60);
        case 'damage':
          _tone(ctx, 110, 0.35, 'sawtooth', 0.07, 35);
        case 'wave':
          _tone(ctx, 440, 0.12, 'sine', 0.04, 660);
        case 'ready':
          _tone(ctx, 660, 0.08, 'sine', 0.04);
      }
    } catch (_) {
      // Audio is decoration: a blocked AudioContext never breaks the game.
    }
  }

  void _tone(
    web.AudioContext ctx,
    double freq,
    double dur,
    String type,
    double vol, [
    double? slideTo,
  ]) {
    final osc = ctx.createOscillator();
    final gain = ctx.createGain();
    final now = ctx.currentTime;
    osc.type = type;
    osc.frequency.setValueAtTime(freq, now);
    if (slideTo != null) {
      osc.frequency.exponentialRampToValueAtTime(
          math.max(1, slideTo), now + dur);
    }
    gain.gain.setValueAtTime(vol, now);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + dur);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start(now);
    osc.stop(now + dur);
  }

  void _noise(web.AudioContext ctx, double dur, double vol) {
    final len = (ctx.sampleRate * dur).round().clamp(1, 1 << 20);
    final buf = ctx.createBuffer(1, len, ctx.sampleRate);
    final data = buf.getChannelData(0).toDart;
    final rand = math.Random();
    for (var i = 0; i < len; i++) {
      data[i] = (rand.nextDouble() * 2 - 1) * (1 - i / len);
    }
    final src = ctx.createBufferSource()
      ..buffer = buf;
    final gain = ctx.createGain();
    gain.gain.setValueAtTime(vol, ctx.currentTime);
    src.connect(gain);
    gain.connect(ctx.destination);
    src.start();
  }
}
