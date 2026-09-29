/// In-memory word graph. A word can have many parents and many children,
/// so this is a graph, not a strict tree.
class WordNode {
  String name;
  Set<String> parents;
  Set<String> children;

  WordNode(this.name, {Set<String>? parents, Set<String>? children})
      : parents = parents ?? <String>{},
        children = children ?? <String>{};
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

  /// Link [parent] -> [child] (parent above, child below). Creates nodes.
  void linkParentChild(String parentRaw, String childRaw) {
    final p = norm(parentRaw);
    final c = norm(childRaw);
    if (p.isEmpty || c.isEmpty || p == c) return;
    final pn = ensure(p);
    final cn = ensure(c);
    pn.name = pn.name.isEmpty ? p : pn.name;
    cn.name = cn.name.isEmpty ? c : cn.name;
    pn.children.add(cn.name.toLowerCase() == cn.name ? cn.name : norm(cn.name));
    // Keep keys/refs normalized to lowercase for stable file round-trips.
    pn.children.removeWhere((e) => e.isEmpty);
    cn.parents.add(norm(pn.name));
    _normalizeRefs(pn);
    _normalizeRefs(cn);
  }

  void _normalizeRefs(WordNode n) {
    n.parents = n.parents.map(norm).where((e) => e.isNotEmpty).toSet();
    n.children = n.children.map(norm).where((e) => e.isNotEmpty).toSet();
    n.parents.remove(norm(n.name));
    n.children.remove(norm(n.name));
  }

  void unlinkParentChild(String parentRaw, String childRaw) {
    final p = get(parentRaw);
    final c = get(childRaw);
    p?.children.remove(norm(childRaw));
    c?.parents.remove(norm(parentRaw));
  }

  /// Delete a word entirely and scrub references to it.
  void deleteWord(String rawName) {
    final key = norm(rawName);
    nodes.remove(key);
    for (final n in nodes.values) {
      n.parents.remove(key);
      n.children.remove(key);
    }
  }

  List<String> childrenOf(String rawName) {
    final n = get(rawName);
    if (n == null) return const [];
    final list = n.children.toList()..sort();
    return list;
  }

  List<String> parentsOf(String rawName) {
    final n = get(rawName);
    if (n == null) return const [];
    final list = n.parents.toList()..sort();
    return list;
  }

  bool get isEmpty => nodes.isEmpty;
}
