/// Data for the flash-card page.
///
/// A [FlashCard] is one forced-retrieval exercise for a single target word
/// or expression. The user is given a scenario and a question, answers from
/// habit, and blocks each default answer until the target is the only thing
/// left to say. Good answers are deliberately NOT stored — only the count
/// and the timestamp of the last success survive. The blocked list is the
/// only list that grows, and nothing clears it automatically.
library;

/// Number of blocked attempts in a session before the target is revealed.
/// Change this one constant to make the exercise easier or harder.
const int kRevealAfterBlocks = 5;

class FlashCard {
  final String id;

  /// Situation the question is asked in. Empty on migrated old cards until
  /// the user fills it in.
  String scenario;

  /// The question asked inside [scenario].
  String question;

  /// The word or expression to learn. Hidden while answering.
  String target;

  /// Bad answers the user has blocked. Grows over time, never auto-cleared.
  final List<String> blocked;

  /// How many times the target was used successfully.
  int goodCount;

  /// When the target was last used successfully (milliseconds), or null.
  int? lastGoodAt;

  /// Next review date (milliseconds), or null.
  int? nextReview;

  FlashCard({
    required this.id,
    this.scenario = '',
    this.question = '',
    required this.target,
    List<String>? blocked,
    this.goodCount = 0,
    this.lastGoodAt,
    this.nextReview,
  }) : blocked = blocked ?? <String>[];

  Map<String, dynamic> toJson() => {
        'id': id,
        'scenario': scenario,
        'question': question,
        'target': target,
        'blocked': blocked,
        'goodCount': goodCount,
        'lastGoodAt': lastGoodAt,
        'nextReview': nextReview,
      };

  static int? _asDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is String && raw.trim().isNotEmpty) {
      return int.tryParse(raw.trim());
    }
    return null;
  }

  static FlashCard? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString().trim();
    // Old bundles used a `word` field; accept it as a safety net.
    final target = (raw['target'] ?? raw['word'] ?? '').toString().trim();
    if (id.isEmpty || target.isEmpty) return null;
    final blocked = <String>[];
    for (final b in (raw['blocked'] is List ? raw['blocked'] as List : const [])) {
      final text = b.toString().trim();
      if (text.isNotEmpty && !blocked.contains(text)) blocked.add(text);
    }
    return FlashCard(
      id: id,
      scenario: (raw['scenario'] ?? '').toString(),
      question: (raw['question'] ?? '').toString(),
      target: target,
      blocked: blocked,
      goodCount: int.tryParse((raw['goodCount'] ?? 0).toString()) ?? 0,
      lastGoodAt: _asDate(raw['lastGoodAt']),
      nextReview: _asDate(raw['nextReview']),
    );
  }
}

// ---------------------------------------------------------------------------
// Legacy bundle/sentence shapes. Kept so existing flashcards.json files can
// be migrated; the new UI no longer writes them.
// ---------------------------------------------------------------------------

class FlashBundle {
  final String id;
  String name;
  final String rootWord;
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

/// Human label for a saved date (time today, date otherwise).
String flashDateLabel(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
  return '${dt.day}/${dt.month}/${dt.year}';
}
