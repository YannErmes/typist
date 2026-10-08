import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'computer_video_base.dart';
import 'frame_link.dart';
import 'storage.dart';

/// Desktop backend: mpv playback of real files. A frame note grabs the
  /// current frame through mpv's screenshot command, shrunk and stored in
  /// the app's images folder.
class ComputerVideo extends ComputerVideoBase {
  /// Where grabbed frames are written. Null means capture is unavailable.
  final StorageService? storage;

  ComputerVideo({this.storage});

  static bool _initialized = false;

  /// Must run before any [Player] exists, so mpv loads with the texture
  /// pipeline already in place. Called from `main()`, not lazily.
  static void ensureInitialized() {
    if (_initialized) return;
    MediaKit.ensureInitialized();
    _initialized = true;
  }

  Player? _player;
  VideoController? _ctrl;
  String _ref = '';
  String _error = '';

  /// Guards against a stale open resuming after a newer one started.
  int _gen = 0;

  /// Tears down overlap. mpv's ANGLE/D3D11 render context is shared per
  /// process, so a new player must never be built while the old one is
  /// still tearing down — that race is what produced black rectangles.
  Future<void> _teardown = Future<void>.value();

  /// Errors are loud in the log and short in the UI.
  StreamSubscription<String>? _errorSub;

  @override
  String get lastError => _error;

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
    _error = '';
    final gen = _gen;
    // Wait for the previous player to be fully gone before building the
    // next one, otherwise two render contexts fight over the same GPU
    // resources and the frame comes out black.
    await _teardown;
    if (gen != _gen) return false;
    try {
      if (ref.trim().isEmpty) return false;
      final file = File(ref);
      if (!await file.exists()) {
        _error = 'File not found at $ref';
        return false;
      }
      ensureInitialized();
      final player = Player();
      final ctrl = VideoController(
        player,
        configuration: const VideoControllerConfiguration(
          // ANGLE/D3D11 texture sharing is the usual source of black
          // frames on Windows; software rendering is slower but solid.
          enableHardwareAcceleration: false,
          hwdec: 'no',
        ),
      );
      if (gen != _gen) {
        await player.dispose();
        return false;
      }
      _player = player;
      _ctrl = ctrl;
      _ref = ref;
      _errorSub = player.stream.error.listen((e) => _error = e);

      // The controller must exist before the file is loaded: it is what
      // installs `vo=libmpv` and creates the texture, and mpv picks its
      // video output the moment a track initialises. Opening first leaves
      // the track bound to the default `vo=null`, which is a black screen
      // with working audio.
      //
      // VideoController defers its native setup to a post-frame callback.
      // Nothing else here schedules a frame — this open is fire-and-forget
      // from a Future, not a build — so without this nudge the controller
      // would never finish creating and open() would hang forever.
      try {
        WidgetsBinding.instance.scheduleFrame();
      } catch (_) {
        // No binding (unit test); the controller still initialises.
      }
      try {
        await ctrl.platform.future.timeout(
          const Duration(seconds: 15),
        );
      } catch (_) {
        _error = 'Could not start the video renderer';
        close();
        return false;
      }
      if (gen != _gen) return false;

      await player.open(Media(file.uri.toString()));
      if (gen != _gen) return false;

      await player.play();
      // Only report success once mpv knows the track size. Without this
      // the caller shows the player card before anything is decodable.
      await _waitForTrack(player);
      if (gen != _gen) return false;
      if (!_hasSize(player)) {
        _error = 'No video track in ${FrameLink.basename(ref)}';
        close();
        return false;
      }
      return true;
    } catch (e) {
      _error = '$e';
      close();
      return false;
    }
  }

  /// Wait until mpv reports a video size, or give up after [timeout].
  /// The size often arrives *before* this is called, so check the current
  /// state first — waiting on the stream blindly would stall every open
  /// for the full timeout.
  Future<void> _waitForTrack(
    Player player, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_hasSize(player)) return;
    try {
      await player.stream.videoParams
          .firstWhere((p) => (p.dw ?? 0) > 0 && (p.dh ?? 0) > 0)
          .timeout(timeout);
    } catch (_) {
      // Timed out; the caller's size check decides.
    }
  }

  bool _hasSize(Player player) =>
      (player.state.width ?? 0) > 0 && (player.state.height ?? 0) > 0;

@override
  void close() {
    _gen++;
    final player = _player;
    final sub = _errorSub;
    _player = null;
    _ctrl = null;
    _ref = '';
    _errorSub = null;
    // NB: _error is deliberately not cleared here. Failure paths set it
    // and *then* call close(), and the caller reads lastError after.
    if (sub != null) {
      unawaited(sub.cancel().catchError((Object _) {}));
    }
    if (player == null) return;
    _teardown = _teardown.then((_) async {
      try {
        await player.dispose();
      } catch (_) {
        // Already disposed, or the handle is gone; nothing to salvage.
      }
    });
  }

  @override
  String displayName(String ref) => FrameLink.basename(ref);

  @override
  Widget buildPlayer() {
    final ctrl = _ctrl;
    if (ctrl == null) return const SizedBox.shrink();
    // Key on the ref so switching notes rebuilds VideoState instead of
    // reusing one whose `_visible` was latched from the previous player.
    return Video(
      key: ValueKey<String>(_ref),
      controller: ctrl,
      fit: BoxFit.contain,
      // Black fill until the first frame lands; nothing else to show.
      fill: const Color(0xFF000000),
    );
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

  /// The exact current frame, as an `images/<name>` reference to embed in
  /// the note. mpv hands back full-resolution JPEG, so it is shrunk first:
  /// a frame lives inside the note's saved JSON, and a raw 1080p grab is
  /// roughly a quarter-megabyte of base64 per frame note.
  @override
  Future<String?> captureFrame() async {
    final player = _player;
    final store = storage;
    if (player == null || store == null) return null;
    try {
      final raw = await player.screenshot(format: 'image/jpeg');
      if (raw == null || raw.isEmpty) return null;
      return await store.saveImageBytes(
        _shrink(raw),
        prefix: 'frame',
      );
    } catch (_) {
      return null;
    }
  }

  /// Cap the long edge and re-encode. Falls back to the original bytes
  /// if decoding fails, so a grab is never lost to a resize problem.
  static Uint8List _shrink(
    Uint8List jpeg, {
    int maxSide = 720,
    int quality = 82,
  }) {
    try {
      final decoded = img.decodeJpg(jpeg);
      if (decoded == null) return jpeg;
      if (decoded.width <= maxSide && decoded.height <= maxSide) return jpeg;
      final resized = (decoded.width >= decoded.height)
          ? img.copyResize(decoded, width: maxSide)
          : img.copyResize(decoded, height: maxSide);
      return Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    } catch (_) {
      return jpeg;
    }
  }
}
