/// Timestamp links for computer-video frame notes. A label like `⏱ 4:37`
/// carries `streamframe://t=277`; tapping it seeks this note's player
/// instead of leaving the app. Pure Dart so it unit-tests anywhere.
class FrameLink {
  /// `4:07` / `1:02:03` style label for a frame note.
  static String formatTime(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final r = s % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    return '${h > 0 ? '$h:' : ''}$mm:${r.toString().padLeft(2, '0')}';
  }

  /// Seek link embedded in a frame-note label.
  static String at(int seconds) =>
      'streamframe://frame?t=${seconds < 0 ? 0 : seconds}';

  /// Seconds encoded in a [FrameLink.at] link, or null for anything else
  /// (web links, legacy YouTube timestamps, garbage).
  static int? secondsOf(String url) {
    try {
      final uri = Uri.parse(url.trim());
      if (uri.scheme != 'streamframe') return null;
      final t = uri.queryParameters['t'];
      if (t == null || !RegExp(r'^\d+$').hasMatch(t)) return null;
      return int.parse(t);
    } catch (_) {
      return null;
    }
  }

  /// File name out of a stored video reference (desktop path or web name).
  static String basename(String ref) {
    final t = ref.trim();
    if (t.isEmpty) return '';
    final parts = t.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? t : parts.last;
  }

  /// True when [ref] is a leftover YouTube link from the old flow
  /// (replaced by computer files; never playable by the local player).
  static bool isLegacyLink(String ref) {
    final t = ref.trim().toLowerCase();
    return t.startsWith('http://') || t.startsWith('https://');
  }
}
