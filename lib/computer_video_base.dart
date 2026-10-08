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
/// Desktop asks mpv for the frame and stores it in the images folder.
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

  /// Why the last [openRef] failed, for the user-facing message.
  /// Empty when the failure has nothing useful to say.
  String get lastError => '';

  /// Inline player widget (only valid while a video is open).
  Widget buildPlayer();

  /// Whole current seconds, 0 when unknown.
  int currentSeconds();

  Future<void> seekTo(int seconds);

  /// Exact current frame as something an image embed can display, or null
  /// when this platform cannot grab one. The value is a reference the
  /// caller resolves through its storage ([StorageService.resolveImage]),
  /// not a path that should be trusted as absolute.
  Future<String?> captureFrame();
}
