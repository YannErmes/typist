/// Data for the Blast typing game.
///
/// Bundles hold picture words picked from the mind-map — no uploads here.
/// Each item keeps the image reference the graph node used, so the game can
/// resolve the very same picture the user sees on the map.
class BlastItem {
  final String word;
  final String image;

  const BlastItem({required this.word, required this.image});

  Map<String, dynamic> toJson() => {'word': word, 'image': image};

  static BlastItem? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final word = (raw['word'] ?? '').toString().trim().toLowerCase();
    final image = (raw['image'] ?? '').toString().trim();
    if (word.isEmpty || image.isEmpty) return null;
    return BlastItem(word: word, image: image);
  }
}

class BlastBundle {
  final String id;
  String title;
  final int createdAt;
  List<BlastItem> items;

  BlastBundle({
    required this.id,
    required this.title,
    required this.items,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'items': [for (final i in items) i.toJson()],
      };

  static BlastBundle? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString().trim();
    final title = (raw['title'] ?? '').toString().trim();
    if (id.isEmpty || title.isEmpty) return null;
    final items = <BlastItem>[];
    for (final e in (raw['items'] is List ? raw['items'] as List : const [])) {
      final item = BlastItem.fromJson(e);
      if (item != null && !items.any((x) => x.word == item.word)) {
        items.add(item);
      }
    }
    final stamp = raw['createdAt'];
    return BlastBundle(
      id: id,
      title: title,
      items: items,
      createdAt: stamp is int
          ? stamp
          : int.tryParse(stamp.toString()) ?? DateTime.now().millisecondsSinceEpoch,
    );
  }
}
