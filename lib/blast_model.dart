/// Data for the Blast typing game.
///
/// Bundles hold picture words picked from the mind-map — no uploads here.
/// Each item keeps the image reference the graph node used, so the game can
/// resolve the very same picture the user sees on the map.
library;

/// Genuinely different track layouts, like the boards in Zuma: a spiral,
/// a round ring, a wide oval, a rounded square, a figure eight and a
/// serpentine wave. Each is drawn by its own path generator in the game.
enum BlastShape {
  spiral('spiral', 'Spiral'),
  ring('ring', 'Ring'),
  oval('oval', 'Oval'),
  square('square', 'Square'),
  figure8('figure8', 'Figure 8'),
  wave('wave', 'Wave');

  final String id;
  final String label;
  const BlastShape(this.id, this.label);

  static BlastShape fromId(String? id) {
    // Old saved ids from the previous round/classic/flat setting.
    final migrated = switch (id) {
      'round' => 'ring',
      'classic' => 'spiral',
      'flat' => 'oval',
      _ => id,
    };
    return BlastShape.values.firstWhere(
      (s) => s.id == migrated,
      orElse: () => BlastShape.spiral,
    );
  }
}

/// Saved track choice: how long the spiral is and how it is shaped.
class BlastTrack {
  final double turns;
  final BlastShape shape;

  const BlastTrack({this.turns = 2.35, this.shape = BlastShape.spiral});

  /// Preset lengths presented in the game's track settings.
  static const lengths = <({String label, double turns})>[
    (label: 'Short', turns: 1.6),
    (label: 'Medium', turns: 2.35),
    (label: 'Long', turns: 3.2),
    (label: 'Extra long', turns: 4.4),
  ];

  static const defaultTurns = 2.35;
}
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
