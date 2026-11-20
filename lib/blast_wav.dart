import 'dart:math' as math;
import 'dart:typed_data';

/// Small synthesized WAV effects for the desktop build. No asset files:
/// each sound is generated once, cached, and handed to the audio player.
const int _rate = 22050;

Uint8List? _cacheFor(String effect) => _cache[effect];
final Map<String, Uint8List> _cache = {};

Uint8List blastWav(String effect) {
  final cached = _cacheFor(effect);
  if (cached != null) return cached;

  final seconds = switch (effect) {
    'lock' => 0.06,
    'shoot' => 0.12,
    'explode' => 0.22,
    'miss' => 0.1,
    'emp' => 0.6,
    'damage' => 0.38,
    'wave' => 0.14,
    'ready' => 0.09,
    _ => 0.08,
  };
  final n = (seconds * _rate).round();
  final mix = Float64List(n);

  void tone(double from, double to, double dur, String shape, double vol,
      [double offset = 0]) {
    final start = (offset * _rate).round();
    final count = (dur * _rate).round();
    var phase = 0.0;
    for (var i = 0; i < count && start + i < n; i++) {
      final u = i / count;
      phase += 2 * math.pi * (from + (to - from) * u) / _rate;
      final wave = switch (shape) {
        'square' => math.sin(phase) >= 0 ? 1.0 : -1.0,
        'saw' => 2 * (phase / (2 * math.pi) -
            (phase / (2 * math.pi) + 0.5).floor()),
        'triangle' => 2 / math.pi * math.asin(math.sin(phase)),
        _ => math.sin(phase),
      };
      mix[start + i] += wave * vol * math.pow(1 - u, 1.6);
    }
  }

  void noise(double dur, double vol, [double offset = 0]) {
    final start = (offset * _rate).round();
    final count = (dur * _rate).round();
    final rand = math.Random();
    for (var i = 0; i < count && start + i < n; i++) {
      mix[start + i] +=
          (rand.nextDouble() * 2 - 1) * vol * math.pow(1 - i / count, 1.4);
    }
  }

  switch (effect) {
    case 'lock':
      tone(880, 880, 0.045, 'square', 0.3);
    case 'shoot':
      tone(320, 70, 0.09, 'saw', 0.35);
      noise(0.05, 0.16);
    case 'explode':
      noise(0.18, 0.3);
      tone(120, 40, 0.18, 'triangle', 0.25);
    case 'miss':
      tone(150, 90, 0.09, 'square', 0.22);
    case 'emp':
      tone(70, 28, 0.55, 'sine', 0.5);
      tone(420, 60, 0.4, 'saw', 0.18);
      noise(0.3, 0.1);
    case 'damage':
      tone(110, 35, 0.35, 'saw', 0.4);
    case 'wave':
      tone(440, 660, 0.12, 'sine', 0.3);
    case 'ready':
      tone(660, 660, 0.08, 'sine', 0.28);
  }

  final bytes = _writeWav(mix);
  _cache[effect] = bytes;
  return bytes;
}

Uint8List _writeWav(Float64List samples) {
  final dataLen = samples.length * 2;
  final out = Uint8List(44 + dataLen);
  final view = ByteData.view(out.buffer);
  void str(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      out[at + i] = s.codeUnitAt(i);
    }
  }

  str(0, 'RIFF');
  view.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little); // PCM
  view.setUint16(22, 1, Endian.little); // mono
  view.setUint32(24, _rate, Endian.little);
  view.setUint32(28, _rate * 2, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  str(36, 'data');
  view.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    var v = samples[i].clamp(-1.0, 1.0);
    view.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return out;
}
