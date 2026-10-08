import 'package:flutter/widgets.dart';

import 'storage.dart';

/// The browser has no local images folder: frames and pasted screenshots
/// arrive as data URLs, which Quill renders on its own.
ImageProvider? resolveEmbedImage(StorageService storage, String url) => null;