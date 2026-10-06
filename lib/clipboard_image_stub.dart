/// Clipboard image paste on platforms without a DOM listener yet.
///
/// The desktop player (and its native paste path) lands later; until then
/// pasting pictures there simply does nothing.
void listenClipboardImages(void Function(String dataUrl) onImage) {}
