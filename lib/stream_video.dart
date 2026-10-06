/// Helpers for the stream-writing video panel: one YouTube link per note,
/// an inline player, and timestamped frame notes (thumbnail + a label that
/// seeks the player back to that moment, with room to type underneath).
///
/// Pure Dart on purpose, so every rule unit-tests on any platform.
class StreamVideo {
  static final RegExp _bareId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  /// The 11-char video id inside watch/shorts/live/embed/youtu.be links
  /// (or a bare id), null when the text holds no recognizable video.
  static String? parseId(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (_bareId.hasMatch(t)) return t;
    Uri? uri;
    try {
      uri = Uri.parse(t.startsWith('http') ? t : 'https://$t');
    } catch (_) {
      return null;
    }
    if (uri.host.isEmpty) return null;
    final host =
        uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    String? id;
    if (host == 'youtu.be') {
      if (uri.pathSegments.isNotEmpty) id = uri.pathSegments.first;
    } else if (host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtube-nocookie.com' ||
        host.endsWith('.youtube-nocookie.com')) {
      final seg = uri.pathSegments;
      if (uri.path == '/watch') {
        id = uri.queryParameters['v'];
      } else if (seg.length >= 2 &&
          (seg[0] == 'embed' ||
              seg[0] == 'shorts' ||
              seg[0] == 'live')) {
        id = seg[1];
      }
    }
    if (id != null && _bareId.hasMatch(id)) return id;
    return null;
  }

  /// Still frame for a frame note (generic poster, not the exact frame:
  /// YouTube never exposes per-second stills to embeds).
  static String thumbnail(String videoId) =>
      'https://img.youtube.com/vi/$videoId/hqdefault.jpg';

  /// Share link that opens the video at [seconds].
  static String timestampUrl(String videoId, int seconds) =>
      'https://youtu.be/$videoId?t=${seconds < 0 ? 0 : seconds}';

  /// `4:07` / `1:02:03` style label for a frame note.
  static String formatTime(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final r = s % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    return '${h > 0 ? '$h:' : ''}$mm:${r.toString().padLeft(2, '0')}';
  }

  /// Seconds encoded in a timestamp link (`?t=277` or `?t=1h2m3s`).
  static int? timestampOf(String url) {
    try {
      final uri = Uri.parse(url.trim());
      final t = uri.queryParameters['t'];
      if (t == null || t.isEmpty) return null;
      if (RegExp(r'^\d+$').hasMatch(t)) return int.parse(t);
      var total = 0;
      var digits = '';
      var seen = false;
      for (var i = 0; i < t.length; i++) {
        final ch = t[i];
        if (RegExp(r'[0-9]').hasMatch(ch)) {
          digits += ch;
          continue;
        }
        final n = int.tryParse(digits) ?? 0;
        digits = '';
        if (ch == 'h') {
          total += n * 3600;
          seen = true;
        } else if (ch == 'm') {
          total += n * 60;
          seen = true;
        } else if (ch == 's') {
          total += n;
          seen = true;
        } else {
          return null;
        }
      }
      if (digits.isNotEmpty) return null;
      return seen ? total : null;
    } catch (_) {
      return null;
    }
  }
}
