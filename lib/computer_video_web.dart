import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'computer_video_base.dart';
import 'frame_link.dart';

/// Web backend: our own `<video>` element (native controls), so the exact
/// pixels are always one canvas draw away. Files live as blob URLs;
/// picked bytes are cached per file name for note switching (a reload
/// clears them — the note then asks for the file again).
class ComputerVideo extends ComputerVideoBase {
  static const _viewType = 'computer-video-player';
  static bool _registered = false;

  final Map<String, Uint8List> _bytes = {};
  web.HTMLVideoElement? _el;
  String? _url;
  String? _ref;

  String? get _openRef => _ref;

  @override
  Future<PickedVideo?> pick() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.video,
      );
      if (files.isEmpty) return null;
      final f = files.single;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      return PickedVideo(name: f.name, bytes: bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  String store(PickedVideo picked) {
    final bytes = picked.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      _bytes[picked.name] =
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    }
    return picked.name;
  }

  @override
  Future<bool> openRef(String ref) async {
    close();
    try {
      final bytes = _bytes[ref];
      if (bytes == null || bytes.isEmpty) return false;
      final blob = web.Blob([bytes.toJS].toJS);
      _url = web.URL.createObjectURL(blob);
      final el = web.HTMLVideoElement()
        ..controls = true
        ..preload = 'auto'
        ..style.width = '100%'
        ..style.height = '100%'
        ..src = _url!;
      _el = el;
      _ref = ref;
      return true;
    } catch (_) {
      close();
      return false;
    }
  }

  @override
  void close() {
    final url = _url;
    _url = null;
    _el = null;
    _ref = null;
    if (url != null) {
      try {
        web.URL.revokeObjectURL(url);
      } catch (_) {}
    }
  }

  @override
  String displayName(String ref) => FrameLink.basename(ref);

  @override
  Widget buildPlayer() {
    if (!_registered) {
      ui_web.platformViewRegistry.registerViewFactory(
          _viewType, (int id) => _el ?? web.HTMLVideoElement());
      _registered = true;
    }
    return HtmlElementView(
      key: ValueKey<String>(_openRef ?? 'none'),
      viewType: _viewType,
    );
  }

  @override
  int currentSeconds() {
    try {
      final t = _el?.currentTime ?? 0;
      return t < 0 ? 0 : t.floor();
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> seekTo(int seconds) async {
    try {
      final el = _el;
      if (el == null) return;
      el.currentTime = (seconds < 0 ? 0 : seconds).toDouble();
      try {
        await el.play().toDart.timeout(const Duration(seconds: 3));
      } catch (_) {}
    } catch (_) {}
  }

  /// The true current frame, straight off our own element.
  @override
  Future<String?> captureFrame() async {
    final el = _el;
    if (el == null) return null;
    try {
      final iw = el.videoWidth;
      final ih = el.videoHeight;
      if (iw <= 0 || ih <= 0) return null;
      const maxSide = 720;
      final big = iw > ih ? iw : ih;
      final scale = big > maxSide ? maxSide / big : 1.0;
      var w = (iw * scale).round();
      var h = (ih * scale).round();
      if (w > maxSide) w = maxSide;
      if (h > maxSide) h = maxSide;
      if (w < 1) w = 1;
      if (h < 1) h = 1;
      final canvas = web.HTMLCanvasElement()
        ..width = w
        ..height = h;
      final ctx = canvas.getContext('2d');
      if (ctx == null || !ctx.isA<web.CanvasRenderingContext2D>()) {
        return null;
      }
      (ctx as web.CanvasRenderingContext2D)
          .drawImage(el, 0, 0, w.toDouble(), h.toDouble());
      return canvas.toDataURL('image/jpeg', 0.82.toJS);
    } catch (_) {
      return null;
    }
  }
}
