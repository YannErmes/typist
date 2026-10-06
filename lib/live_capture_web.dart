import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// One live tab-capture session for stream writing: after a single browser
/// pick, every frame note grabs exactly what the floating player shows
/// (cropped to its on-screen rect), with no further popups.
///
/// Why this exists: YouTube's iframe never exposes pixels to the page
/// (cross-origin), so the only faithful capture is the displayed screen.
/// Tab capture keeps the mapping exact: captured pixels = viewport pixels,
/// so the player's CSS rect scales cleanly onto the frame.
class LiveCapture {
  web.MediaStream? _stream;
  web.HTMLVideoElement? _el;

  /// Fires when the user stops sharing from the browser chrome.
  void Function()? onEnded;

  bool get live {
    final s = _stream;
    if (s == null) return false;
    try {
      if (!s.active) return false;
      final tracks = s.getVideoTracks().toDart;
      if (tracks.isEmpty) return false;
      return tracks.first.readyState == 'live';
    } catch (_) {
      return false;
    }
  }

  /// Ask the browser for a tab capture (one picker per session).
  /// True when a live stream with real dimensions is flowing.
  Future<bool> start() async {
    stop();
    try {
      final stream = await web.window.navigator.mediaDevices
          .getDisplayMedia(web.DisplayMediaStreamOptions(
            video: true.toJS,
            audio: false.toJS,
          ))
          .toDart;
      final el = web.HTMLVideoElement()..muted = true;
      el.srcObject = stream;
      try {
        await el.play().toDart.timeout(const Duration(seconds: 5));
      } catch (_) {}
      for (var i = 0; i < 30 && el.videoWidth == 0; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (el.videoWidth == 0) {
        stop();
        return false;
      }
      _stream = stream;
      _el = el;
      for (final t in stream.getVideoTracks().toDart) {
        t.addEventListener(
            'ended',
            ((web.Event _) {
              stop();
              onEnded?.call();
            }).toJS);
      }
      return true;
    } catch (_) {
      // User cancelled the picker, or capture is blocked: the timestamp
      // fallback still marks the second.
      stop();
      return false;
    }
  }

  void stop() {
    try {
      final s = _stream;
      if (s != null) {
        for (final t in s.getTracks().toDart) {
          try {
            t.stop();
          } catch (_) {}
        }
      }
    } catch (_) {}
    _stream = null;
    try {
      _el?.srcObject = null;
    } catch (_) {}
    _el = null;
  }

  /// Crop the player's CSS rect out of the live capture and return it as
  /// a note-friendly JPEG data URL (720px). Null when the stream is not
  /// flowing or the rect misses the frame (e.g. a window/screen was
  /// shared instead of the tab).
  Future<String?> grab(
      double cssX, double cssY, double cssW, double cssH) async {
    final el = _el;
    if (el == null || !live) return null;
    try {
      final fw = el.videoWidth;
      final fh = el.videoHeight;
      if (fw <= 0 || fh <= 0) return null;
      final innerW = web.window.innerWidth;
      if (innerW <= 0) return null;
      final scale = fw / innerW; // captured px per CSS px
      var sx = cssX * scale;
      var sy = cssY * scale;
      var sw = cssW * scale;
      var sh = cssH * scale;
      if (sx < 0) {
        sw += sx;
        sx = 0;
      }
      if (sy < 0) {
        sh += sy;
        sy = 0;
      }
      if (sx + sw > fw) sw = (fw - sx).toDouble();
      if (sy + sh > fh) sh = (fh - sy).toDouble();
      if (sw < 8 || sh < 8) return null;
      const maxSide = 720;
      final big = sw > sh ? sw : sh;
      final k = big > maxSide ? maxSide / big : 1.0;
      final cw = (sw * k).round().clamp(1, maxSide);
      final ch = (sh * k).round().clamp(1, maxSide);
      final canvas = web.HTMLCanvasElement()
        ..width = cw
        ..height = ch;
      final ctx = canvas.getContext('2d');
      if (ctx == null || !ctx.isA<web.CanvasRenderingContext2D>()) {
        return null;
      }
      (ctx as web.CanvasRenderingContext2D)
          .drawImage(el, sx, sy, sw, sh, 0, 0, cw, ch);
      return canvas.toDataURL('image/jpeg', 0.82.toJS);
    } catch (_) {
      return null;
    }
  }
}
