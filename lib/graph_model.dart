/// In-memory word network. Words are free nodes on a mind-map canvas;
/// links between them are plain undirected connections (no hierarchy).
class WordNode {
  String name;
  Set<String> links;

  /// Saved canvas position. Null = auto-place.
  double? x;
  double? y;

  /// Saved card color as ARGB int. Null = default paper.
  int? color;

  /// Hidden definition shown when editing the word. Null/empty = none yet.
  String? meaning;

  /// Picture attached to this node: `http...` URL, `images/<file>` path
  /// relative to the app folder, or `mem:<key>` session preview.
  /// Null = plain word bubble.
  String? image;

  /// Jump-link numbers by neighbor key: a pair sharing a number is
  /// connected without drawing the long line between them.
  Map<String, String> jumps;

  WordNode(this.name,
      {Set<String>? links,
      this.x,
      this.y,
      this.color,
      this.meaning,
      this.image,
      Map<String, String>? jumps})
      : links = links ?? <String>{},
        jumps = jumps ?? <String, String>{};

  bool get hasPos => x != null && y != null;
  bool get hasImage => image != null && image!.trim().isNotEmpty;
}

class WordGraph {
  final Map<String, WordNode> nodes = {};

  static String norm(String s) => s.trim().toLowerCase();

  WordNode ensure(String rawName) {
    final key = norm(rawName);
    return nodes.putIfAbsent(key, () => WordNode(rawName.trim()));
  }

  WordNode? get(String rawName) => nodes[norm(rawName)];

  List<String> sortedKeys() {
    final keys = nodes.keys.toList()..sort();
    return keys;
  }

  /// Connect two words (undirected). Creates missing nodes.
  void connect(String aRaw, String bRaw) {
    final a = norm(aRaw);
    final b = norm(bRaw);
    if (a.isEmpty || b.isEmpty || a == b) return;
    final an = ensure(a);
    final bn = ensure(b);
    an.links.add(norm(bn.name));
    bn.links.add(norm(an.name));
    _scrub(an);
    _scrub(bn);
  }

  void _scrub(WordNode n) {
    n.links =
        n.links.map(norm).where((e) => e.isNotEmpty).toSet();
    n.links.remove(norm(n.name));
  }

  bool linked(String aRaw, String bRaw) {
    final a = get(aRaw);
    if (a == null) return false;
    return a.links.contains(norm(bRaw));
  }

  void disconnect(String aRaw, String bRaw) {
    get(aRaw)?.links.remove(norm(bRaw));
    get(bRaw)?.links.remove(norm(aRaw));
    get(aRaw)?.jumps.remove(norm(bRaw));
    get(bRaw)?.jumps.remove(norm(aRaw));
  }

  /// Shared jump number for a pair, or null for a solid line.
  String? jumpNumber(String aRaw, String bRaw) {
    final a = norm(aRaw);
    final b = norm(bRaw);
    return get(a)?.jumps[b] ?? get(b)?.jumps[a];
  }

  /// Turn the link between two words into a numbered jump (or back to a
  /// solid line when [number] is null/empty). Creates the link if missing.
  void setJump(String aRaw, String bRaw, String? number) {
    final a = norm(aRaw);
    final b = norm(bRaw);
    if (a.isEmpty || b.isEmpty || a == b) return;
    connect(a, b);
    final num = (number ?? '').trim();
    if (num.isEmpty) {
      get(a)?.jumps.remove(b);
      get(b)?.jumps.remove(a);
    } else {
      get(a)?.jumps[b] = num;
      get(b)?.jumps[a] = num;
    }
  }

  /// Rename a word, keeping its links, jump numbers, position and color.
  /// Returns false when the name is taken or invalid.
  bool rename(String oldRaw, String newRaw) {
    final oldKey = norm(oldRaw);
    final newKey = norm(newRaw);
    if (oldKey.isEmpty || newKey.isEmpty || oldKey == newKey) {
      return false;
    }
    if (nodes.containsKey(newKey)) return false;
    final node = nodes.remove(oldKey);
    if (node == null) return false;
    node.name = newRaw.trim();
    nodes[newKey] = node;
    for (final n in nodes.values) {
      if (n.links.remove(oldKey)) n.links.add(newKey);
      final jump = n.jumps.remove(oldKey);
      if (jump != null) n.jumps[newKey] = jump;
    }
    return true;
  }

  /// Delete a word entirely and scrub references to it.
  void deleteWord(String rawName) {
    final key = norm(rawName);
    nodes.remove(key);
    for (final n in nodes.values) {
      n.links.remove(key);
      n.jumps.remove(key);
    }
  }

  List<String> neighborsOf(String rawName) {
    final n = get(rawName);
    if (n == null) return const [];
    final list = n.links.toList()..sort();
    return list;
  }

  bool get isEmpty => nodes.isEmpty;
}

/// Whole-word, case-insensitive matches with the graph word each hit.
/// Shared by the writing highlight pass and the repetition practice check.
List<({int start, int end, String word})> findGraphMatches(
    String text, List<String> words) {
  final result = <({int start, int end, String word})>[];
  final keys = words.where((w) => w.trim().isNotEmpty).toList();
  if (keys.isEmpty || text.isEmpty) return result;
  final lower = <String, String>{};
  for (final k in keys) {
    lower.putIfAbsent(k.toLowerCase(), () => k);
  }
  final escaped = lower.keys.map(RegExp.escape).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final re =
      RegExp('\\b(?:${escaped.join('|')})\\b', caseSensitive: false);
  for (final m in re.allMatches(text)) {
    result.add(
        (start: m.start, end: m.end, word: lower[m.group(0)!.toLowerCase()]!));
  }
  return result;
}
