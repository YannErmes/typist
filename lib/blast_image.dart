import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'image_embed.dart';
import 'storage.dart';

/// Image provider for a picture word carried from the map into a Blast
/// bundle. Graph nodes use `images/<file>` on desktop, a data URL for
/// browser-picked pictures, or a plain http link.
ImageProvider? blastImageProvider(StorageService storage, String ref) {
  final t = ref.trim();
  if (t.isEmpty) return null;
  if (t.startsWith('data:')) {
    final comma = t.indexOf(',');
    if (comma < 0) return null;
    try {
      return MemoryImage(base64Decode(t.substring(comma + 1)));
    } catch (_) {
      return null;
    }
  }
  if (t.startsWith('http://') || t.startsWith('https://')) {
    return NetworkImage(t);
  }
  return resolveEmbedImage(storage, t);
}

/// Turn browser-picked (`mem:`) bytes into a portable data URL so a picked
/// picture survives closing the map picker.
String blastDataUrl(Uint8List bytes) {
  var mime = 'image/jpeg';
  if (bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50) {
    mime = 'image/png';
  } else if (bytes.length > 3 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    mime = 'image/gif';
  }
  return 'data:$mime;base64,${base64Encode(bytes)}';
}
