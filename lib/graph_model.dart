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

  WordNode(this.name,
      {Set<String>? links, this.x, this.y, this.color})
      : links = links ?? <String>{};

  bool get hasPos => x != null && y != null;
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
  }

  /// Rename a word, keeping its links, position and color.
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
    }
    return true;
  }

  /// Delete a word entirely and scrub references to it.
  void deleteWord(String rawName) {
    final key = norm(rawName);
    nodes.remove(key);
    for (final n in nodes.values) {
      n.links.remove(key);
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
