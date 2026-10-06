import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Forward pasted image files (screenshot snippets, exact video frames)
/// as downscaled JPEG data URLs. The caller inserts them into the open
/// note; text pastes are untouched.
void listenClipboardImages(void Function(String dataUrl) onImage) {
  web.document.addEventListener(
      'paste',
      ((web.Event event) {
        if (!event.isA<web.ClipboardEvent>()) return;
        final clip = event as web.ClipboardEvent;
        final files = clip.clipboardData?.files;
        if (files == null || files.length == 0) return;
        web.File? image;
        for (var i = 0; i < files.length; i++) {
          final file = files.item(i);
          if (file != null && file.type.startsWith('image/')) {
            image = file;
            break;
          }
        }
        final picked = image;
        if (picked == null) return;
        // Swallow the paste: the pixels go to the note, not the DOM.
        event.preventDefault();
        final reader = web.FileReader();
        reader.addEventListener(
            'load',
            ((web.Event _) {
              final result = reader.result;
              if (result == null || !result.isA<JSString>()) return;
              _downscale((result as JSString).toDart, onImage);
            }).toJS);
        reader.readAsDataURL(picked);
      }).toJS);
}

/// Shrink big screenshots to a note-friendly JPEG (720px, ~80-150KB so
/// session files stay light), then hand the data URL back.
void _downscale(String dataUrl, void Function(String dataUrl) onImage) {
  final img = web.HTMLImageElement();
  img.addEventListener(
      'load',
      ((web.Event _) {
        final iw = img.naturalWidth;
        final ih = img.naturalHeight;
        if (iw <= 0 || ih <= 0) return;
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
        if (ctx != null &&
            ctx.isA<web.CanvasRenderingContext2D>()) {
          (ctx as web.CanvasRenderingContext2D)
              .drawImage(img, 0, 0, w, h);
          onImage(
              canvas.toDataURL('image/jpeg', 0.82.toJS));
        }
      }).toJS);
  img.src = dataUrl;
}
