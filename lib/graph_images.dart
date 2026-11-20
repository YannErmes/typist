import 'dart:convert';
import 'dart:typed_data';

/// Pictures picked in the browser live as `mem:<key>` references. They used
/// to sit inside a single GraphView, so a second graph (the Blast picker)
/// saw broken images and could not carry the picture into a bundle.
///
/// Keeping the bytes here makes every GraphView in the app see the same
/// pictures for the lifetime of the session.
class GraphImages {
  static final Map<String, Uint8List> memory = <String, Uint8List>{};

  static void put(String ref, Uint8List bytes) => memory[ref] = bytes;

  static Uint8List? get(String ref) => memory[ref];
}

/// Decode a `data:...;base64,...` picture ref, or null for other refs.
Uint8List? graphDataBytes(String ref) {
  final t = ref.trim();
  if (!t.startsWith('data:')) return null;
  final comma = t.indexOf(',');
  if (comma < 0) return null;
  try {
    return base64Decode(t.substring(comma + 1));
  } catch (_) {
    return null;
  }
}

/// Store a browser-picked picture as a data URL on the word itself. Unlike
/// a `mem:` ref it survives closing the page and every other GraphView can
/// read it without needing this process's memory.
String graphDataUrl(Uint8List bytes) {
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
