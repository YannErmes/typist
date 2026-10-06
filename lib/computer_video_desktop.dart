import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'computer_video_base.dart';
import 'frame_link.dart';

/// Desktop backend: mpv playback of real files. mpv exposes no frame grab
/// here, so [captureFrame] stays null and a frame note is the timestamp
/// label (seekable) plus the user's own snip.
class ComputerVideo extends ComputerVideoBase {
  static bool _initialized = false;

  Player? _player;
  VideoController? _ctrl;

  void _ensure() {
    if (_initialized) return;
    try {
      MediaKit.ensureInitialized();
    } catch (_) {}
    _initialized = true;
  }

  @override
  Future<PickedVideo?> pick() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.video,
      );
      if (files.isEmpty) return null;
      final f = files.single;
      final path = f.path;
      if (path == null || path.isEmpty) return null;
      return PickedVideo(name: f.name, path: path);
    } catch (_) {
      return null;
    }
  }

  @override
  String store(PickedVideo picked) {
    final path = picked.path;
    return (path == null || path.isEmpty) ? picked.name : path;
  }

  @override
  Future<bool> openRef(String ref) async {
    close();
    try {
      if (ref.trim().isEmpty) return false;
      if (!await File(ref).exists()) return false;
      _ensure();
      final player = Player();
      await player.open(Media(ref));
      _ctrl = VideoController(player);
      _player = player;
      return true;
    } catch (_) {
      close();
      return false;
    }
  }

  @override
  void close() {
    _ctrl = null;
    final player = _player;
    _player = null;
    if (player != null) {
      // Disposing the player releases its video controller too.
      try {
        player.dispose();
      } catch (_) {}
    }
  }

  @override
  String displayName(String ref) => FrameLink.basename(ref);

  @override
  Widget buildPlayer() {
    final ctrl = _ctrl;
    if (ctrl == null) return const SizedBox.shrink();
    return Video(controller: ctrl);
  }

  @override
  int currentSeconds() {
    try {
      final s = _player?.state.position.inSeconds ?? 0;
      return s < 0 ? 0 : s;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> seekTo(int seconds) async {
    try {
      final player = _player;
      if (player == null) return;
      await player.seek(Duration(seconds: seconds < 0 ? 0 : seconds));
      try {
        await player.play();
      } catch (_) {}
    } catch (_) {}
  }

  @override
  Future<String?> captureFrame() async => null;
}
