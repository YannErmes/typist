import 'package:flutter/widgets.dart';

/// A video file picked from this computer (name always present; bytes on
/// web, a filesystem path on desktop).
class PickedVideo {
  final String name;
  final String? path;
  final List<int>? bytes;
  PickedVideo({required this.name, this.path, this.bytes});
}

/// One note's local video player: file picking, inline playback, exact
/// frame capture and second-accurate seeking.
///
/// Web plays through our own element, so capture is the true pixels.
/// Desktop plays through mpv, which exposes no frame grab — there a
/// frame note is the timestamp label plus the user's own snip.
abstract class ComputerVideoBase {
  /// Ask the OS for a video file. Null when the user cancels.
  Future<PickedVideo?> pick();

  /// Persist [picked] and return the reference stored on the session
  /// (desktop path, web file name).
  String store(PickedVideo picked);

  /// Open a stored reference. False when it cannot play
  /// (web reload cleared the bytes, desktop file moved/deleted).
  Future<bool> openRef(String ref);

  void close();

  /// Display name for a stored reference.
  String displayName(String ref);

  /// Inline player widget (only valid while a video is open).
  Widget buildPlayer();

  /// Whole current seconds, 0 when unknown.
  int currentSeconds();

  Future<void> seekTo(int seconds);

  /// Exact current frame as a note-friendly JPEG data URL, or null when
  /// this platform cannot grab (desktop).
  Future<String?> captureFrame();
}
