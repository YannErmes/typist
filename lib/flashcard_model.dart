/// Data for the flash-card page.
///
/// A [FlashBundle] is one named exercise: a root word plus a snapshot of
/// every word directly linked to it. Sentences are stored separately and
/// always keyed by the word they belong to, so the same word can collect
/// sentences across many bundles over time — flipping any card shows the
/// whole history, while opening a bundle shows only what was written in it.
class FlashBundle {
  final String id;
  String name;
  final String rootWord;

  /// Card order, fixed when the bundle is created so later map edits do
  /// not reshuffle an exercise someone is in the middle of.
  final List<String> words;
  final int createdAt;
  int updatedAt;

  FlashBundle({
    required this.id,
    required this.name,
    required this.rootWord,
    required this.words,
    required this.createdAt,
    int? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'rootWord': rootWord,
        'words': words,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  static FlashBundle? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString().trim();
    final root = (raw['rootWord'] ?? '').toString().trim().toLowerCase();
    if (id.isEmpty || root.isEmpty) return null;
    final words = <String>[];
    for (final w in (raw['words'] is List ? raw['words'] as List : const [])) {
      final key = w.toString().trim().toLowerCase();
      if (key.isNotEmpty && !words.contains(key)) words.add(key);
    }
    if (!words.contains(root)) words.insert(0, root);
    int asInt(dynamic v, int fallback) =>
        v is int ? v : int.tryParse(v.toString()) ?? fallback;
    final name = (raw['name'] ?? '').toString().trim();
    return FlashBundle(
      id: id,
      name: name.isEmpty ? '$root cards' : name,
      rootWord: root,
      words: words,
      createdAt: asInt(raw['createdAt'], DateTime.now().millisecondsSinceEpoch),
      updatedAt: asInt(raw['updatedAt'], DateTime.now().millisecondsSinceEpoch),
    );
  }
}

/// One sentence written on the back of a word's card during a bundle.
class FlashSentence {
  final String id;
  final String bundleId;
  final String word;
  final String text;
  final int createdAt;

  FlashSentence({
    required this.id,
    required this.bundleId,
    required this.word,
    required this.text,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'bundleId': bundleId,
        'word': word,
        'text': text,
        'createdAt': createdAt,
      };

  static FlashSentence? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString().trim();
    final bundleId = (raw['bundleId'] ?? '').toString().trim();
    final word = (raw['word'] ?? '').toString().trim().toLowerCase();
    final text = (raw['text'] ?? '').toString().trim();
    if (id.isEmpty || bundleId.isEmpty || word.isEmpty || text.isEmpty) {
      return null;
    }
    final stamp = raw['createdAt'];
    final createdAt = stamp is int
        ? stamp
        : int.tryParse(stamp.toString()) ?? DateTime.now().millisecondsSinceEpoch;
    return FlashSentence(
      id: id,
      bundleId: bundleId,
      word: word,
      text: text,
      createdAt: createdAt,
    );
  }
}

/// Short date for a saved sentence (time today, date otherwise).
String flashDateLabel(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
  return '${dt.day}/${dt.month}/${dt.year}';
}
