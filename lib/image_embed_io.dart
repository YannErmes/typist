import 'dart:io';

import 'package:flutter/widgets.dart';

import 'storage.dart';

/// Resolve an image embed's stored value to something displayable.
///
/// Notes hold a portable `images/<name>` reference, not an absolute path,
/// so the reference is resolved here against the app's images folder.
/// Returning null hands the value back to Quill, which knows how to
/// render data URLs and network images itself.
ImageProvider? resolveEmbedImage(StorageService storage, String url) {
  final ref = url.trim();
  if (ref.isEmpty) return null;
  if (ref.startsWith('data:') ||
      ref.startsWith('http://') ||
      ref.startsWith('https://')) {
    return null;
  }
  final path = storage.resolveImage(ref);
  if (path == null || path.isEmpty) return null;
  return FileImage(File(path));
}