import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'graph_model.dart';
import 'storage.dart';
import 'theme.dart';

/// Mind-map board showing the WHOLE word network as trees.
///
/// Roots (words with no parents) sit at the top, children hang below —
/// adding a parent puts it above, adding a child puts it below.
/// Related words are joined by soft bendy arrows pointing downward.
/// Drag the background to wander, scroll to zoom, drag bubbles to arrange,
/// click a bubble to edit it in the bar above.
class GraphView extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  final VoidCallback onGraphChanged;

  /// Word to focus when the view first opens (e.g. from a sheet tag).
  final String? initialWord;

  /// Fires whenever the focused word changes (null when deleted).
  final ValueChanged<String?>? onSelectionChanged;

  const GraphView({
    super.key,
    required this.storage,
    required this.graph,
    required this.onGraphChanged,
    this.initialWord,
    this.onSelectionChanged,
  });

  @override
  State<GraphView> createState() => GraphViewState();
}

class _Placed {
  final String word;
  Offset center;
  _Placed(this.word, this.center);
}

class _Edge {
  final Offset from; // bottom-center of parent bubble
  final Offset to; // top-center of child bubble
  final String parent;
  final String child;
  final Offset mid; // curve midpoint, for the delete chip + hit-testing
  _Edge(this.from, this.to, this.parent, this.child, this.mid);
}

/// Shared curve math so layout, hit-testing and painting agree.
({Offset c1, Offset c2}) _edgeCurve(Offset from, Offset to) {
  final dy = (to.dy - from.dy).clamp(24.0, 600.0);
  return (
    c1: Offset(from.dx, from.dy + dy * 0.55),
    c2: Offset(to.dx, to.dy - dy * 0.55),
  );
}

Offset _cubicAt(Offset p0, Offset c1, Offset c2, Offset p3, double t) {
  final u = 1 - t;
  return p0 * (u * u * u) +
      c1 * (3 * u * u * t) +
      c2 * (3 * u * t * t) +
      p3 * (t * t * t);
}

double _distToEdge(Offset pt, _Edge e) {
  final c = _edgeCurve(e.from, e.to);
  var best = double.infinity;
  for (var i = 0; i <= 24; i++) {
    final p = _cubicAt(e.from, c.c1, c.c2, e.to, i / 24);
    final d = (p - pt).distance;
    if (d < best) best = d;
  }
  return best;
}

/// Bubble footprint plus breathing room, used for overlap checks.
Rect _nodeRect(Offset c) => Rect.fromCenter(
      center: c,
      width: GraphViewState._nodeW + 24,
      height: GraphViewState._nodeH + 30,
    );

class GraphViewState extends State<GraphView> {
  String? _selected;
  final _childCtrl = TextEditingController();
  final _parentCtrl = TextEditingController();
  final _jumpCtrl = TextEditingController();
  final TransformationController _pan = TransformationController();

  /// User drag offsets per word, applied on top of the auto tree layout.
  Map<String, Offset> _drag = {};

  /// Words pinned to an exact canvas spot (double-click placement).
  Map<String, Offset> _customPos = {};

  /// Link-drawing mode: drag from one bubble to another to attach them.
  bool _linkMode = false;
  String? _linkFrom;
  Offset? _linkFromPt; // canvas coords, temp line start
  Offset? _linkToPt; // canvas coords, temp line end

  /// Word currently being dragged (canvas panning locks while set,
  /// so the bubble follows the cursor exactly).
  String? _draggingNode;

  /// Selected arrow (parent -> child link), shown with a delete chip.
  ({String parent, String child})? _selEdge;
  Offset? _tapDownPt; // canvas coords of the last press on empty canvas

  /// Coalesces rapid drag updates into one rebuild per frame.
  bool _dragScheduled = false;
  void _coalesceRebuild() {
    if (_dragScheduled) return;
    _dragScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dragScheduled = false;
      if (mounted) setState(() {});
    });
  }

  /// Last computed layout, for hit-testing gestures.
  Map<String, Offset> _lastPlaced = {};
  List<_Edge> _lastEdges = [];
  Size _lastCanvas = Size.zero;
  final GlobalKey _canvasKey = GlobalKey();

  static const double _nodeW = 148;
  static const double _nodeH = 42;
  static const double _slotGap = 196;
  static const double _levelGap = 148;
  static const double _margin = 140;

  @override
  void dispose() {
    _childCtrl.dispose();
    _parentCtrl.dispose();
    _jumpCtrl.dispose();
    _pan.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Adopt saved arrangement: the map opens exactly as it was left.
    for (final n in widget.graph.nodes.values) {
      if (n.hasPos) {
        _customPos[WordGraph.norm(n.name)] = Offset(n.x!, n.y!);
      }
    }
    final init = widget.initialWord;
    if (init != null && widget.graph.get(init) != null) {
      _selected = WordGraph.norm(init);
      _pendingCenter = _selected; // sheet opens scrolled to the word
    }
  }

  /// Word to scroll to once the canvas has laid out (then consumed).
  String? _pendingCenter;

  void _centerOnWord(String word, Size viewport) {
    final c = _lastPlaced[word];
    if (c == null) return;
    const s = 1.0;
    _pan.value = Matrix4.translationValues(
      viewport.width / 2 - c.dx * s,
      viewport.height / 2 - c.dy * s,
      0.0,
    );
  }

  Future<void> _persist() async {
    _syncPositions();
    await _saveGraphNow();
  }

  Future<void> _saveGraphNow() async {
    await widget.storage.saveGraph(widget.graph);
    widget.onGraphChanged();
    if (mounted) setState(() {});
  }

  /// Push the on-screen arrangement into the model so it survives restarts.
  /// Pinned spots win; auto-placed newcomers get pinned where they landed.
  void _syncPositions() {
    _customPos.removeWhere((k, _) => !widget.graph.nodes.containsKey(k));
    _drag.removeWhere((k, _) => !widget.graph.nodes.containsKey(k));
    for (final e in _customPos.entries) {
      final n = widget.graph.get(e.key);
      if (n != null) {
        n.x = e.value.dx;
        n.y = e.value.dy;
      }
    }
    for (final p in _lastPlaced.entries) {
      final n = widget.graph.get(p.key);
      if (n != null && !n.hasPos && !_customPos.containsKey(p.key)) {
        n.x = p.value.dx;
        n.y = p.value.dy;
        _customPos[p.key] = p.value;
      }
    }
  }

  void _select(String word) {
    setState(() {
      _selected = WordGraph.norm(word);
      _selEdge = null;
      _childCtrl.clear();
      _parentCtrl.clear();
    });
    widget.onSelectionChanged?.call(_selected);
  }

  /// Empty-canvas press: remember where, for edge picking on tap release.
  void _canvasTapDown(Offset global) {
    _tapDownPt = _toCanvas(global);
  }

  /// Empty-canvas tap: select the nearest arrow, or clear the selection.
  void _canvasTap() {
    final pt = _tapDownPt;
    _tapDownPt = null;
    if (pt == null || _linkMode) return;
    if (_bubbleAt(pt) != null) return; // the bubble's own tap handles it
    // Generous, zoom-aware grab radius so lines stay tappable when zoomed out.
    final scale =
        _pan.value.getMaxScaleOnAxis().clamp(0.3, 2.5);
    _Edge? best;
    var bestD = 30.0 / scale;
    for (final e in _lastEdges) {
      final d = _distToEdge(pt, e);
      if (d < bestD) {
        bestD = d;
        best = e;
      }
    }
    setState(() {
      _selEdge =
          best == null ? null : (parent: best.parent, child: best.child);
    });
  }

  Future<void> _deleteSelectedEdge() async {
    final sel = _selEdge;
    if (sel == null) return;
    widget.graph.unlinkParentChild(sel.parent, sel.child);
    setState(() => _selEdge = null);
    await _persist();
    _notice('Link removed.');
  }

  /// Test hooks: canvas coords of an arrow's midpoint, and canvas->screen.
  @visibleForTesting
  Offset? debugEdgeMid(String parent, String child) {
    for (final e in _lastEdges) {
      if (e.parent == parent && e.child == child) return e.mid;
    }
    return null;
  }

  @visibleForTesting
  Offset debugToGlobal(Offset canvasPt) {
    final box =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return canvasPt;
    return box.localToGlobal(canvasPt);
  }

  void _resetView() {
    // Tidy button: forget every saved spot and auto-arrange from scratch.
    setState(() {
      _drag = {};
      _customPos = {};
      _selEdge = null;
    });
    for (final n in widget.graph.nodes.values) {
      n.x = null;
      n.y = null;
    }
    _saveGraphNow();
    // Land back on the focused word when there is one.
    final sel = _selected;
    if (sel != null && _lastPlaced.containsKey(sel)) {
      _pendingCenter = sel;
      setState(() {});
    } else {
      _pan.value = Matrix4.identity();
    }
  }

  void _notice(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            style: const TextStyle(
                color: PaperTheme.ink, fontSize: 12)),
        backgroundColor: PaperTheme.card,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Screen point -> canvas point (pan/zoom aware).
  Offset _toCanvas(Offset global) {
    final box =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return global;
    return box.globalToLocal(global);
  }

  /// Which bubble contains this canvas point, if any.
  String? _bubbleAt(Offset pt) {
    for (final e in _lastPlaced.entries) {
      final c = e.value;
      if ((pt.dx - c.dx).abs() <= _nodeW / 2 + 8 &&
          (pt.dy - c.dy).abs() <= _nodeH / 2 + 8) {
        return e.key;
      }
    }
    return null;
  }

  Future<String?> _askWordName(
      {required String title, required String hint}) async {
    final ctrl = TextEditingController();
    final field = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: PaperTheme.lineThin),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF4EEDF),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Text(title,
            style: const TextStyle(
                color: PaperTheme.ink,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (_) => Navigator.of(ctx)
              .pop(ctrl.text.trim().toLowerCase()),
          style:
              const TextStyle(color: PaperTheme.ink, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle:
                const TextStyle(color: PaperTheme.inkSoft, fontSize: 13),
            filled: true,
            fillColor: PaperTheme.surface,
            border: field,
            enabledBorder: field,
            focusedBorder: field,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: PaperTheme.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx)
                .pop(ctrl.text.trim().toLowerCase()),
            child: const Text('Create',
                style: TextStyle(
                    color: PaperTheme.ink,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return null;
    return name.trim().toLowerCase();
  }

  /// Double-click on empty canvas: plant a brand-new word right there.
  Future<void> _newWordAt(Offset scene) async {
    final name = await _askWordName(
        title: 'New word', hint: 'e.g. snack');
    if (name == null || !mounted) return;
    widget.graph.ensure(name);
    setState(() {
      _customPos[name] = Offset(
        scene.dx.clamp(
            90, (_lastCanvas.width - 90).clamp(90, 1e6)),
        scene.dy.clamp(
            60, (_lastCanvas.height - 60).clamp(60, 1e6)),
      );
    });
    _select(name);
    await _persist();
    _notice('"$name" planted — drag a link from it to attach it.');
  }

  /// Double-click with no canvas yet (empty graph): just create the word.
  Future<void> _newWordAnywhere() async {
    final name = await _askWordName(
        title: 'First word', hint: 'e.g. eat');
    if (name == null || !mounted) return;
    widget.graph.ensure(name);
    _select(name);
    await _persist();
  }

  /// Double-click a bubble: quickly grow a child under it, fanned out
  /// beside its siblings so nothing overlaps.
  Future<void> _quickChild(String parent) async {
    final name = await _askWordName(
        title: 'Under "$parent"', hint: 'child of "$parent"…');
    if (name == null || !mounted) return;
    widget.graph.ensure(name);
    widget.graph.linkParentChild(parent, name);
    final sibs = widget.graph.childrenOf(parent);
    final i = sibs.indexOf(name).clamp(0, 1 << 30);
    final pc = _lastPlaced[parent] ?? const Offset(500, 300);
    setState(() {
      _customPos[name] = Offset(
        pc.dx + (i - (sibs.length - 1) / 2) * _slotGap,
        pc.dy + _levelGap,
      );
    });
    _select(name);
    await _persist();
  }

  void _toggleLinkMode() {
    setState(() {
      _linkMode = !_linkMode;
      _linkFrom = null;
      _linkFromPt = null;
      _linkToPt = null;
      _selEdge = null;
    });
  }

  /// Tap-tap linking while the link tool is on.
  void _linkTap(String word) {
    if (_linkFrom == null) {
      setState(() => _linkFrom = word);
      _notice('From "$word" — tap another bubble to attach.');
    } else if (_linkFrom == word) {
      setState(() => _linkFrom = null);
    } else {
      final from = _linkFrom!;
      setState(() => _linkFrom = word); // chain: keep linking onwards
      _commitLink(from, word);
    }
  }

  void _nodePanDown(String word, Offset global) {
    if (!_linkMode) {
      // Lock canvas panning so the bubble tracks the cursor 1:1.
      setState(() => _draggingNode = word);
      return;
    }
    final c = _lastPlaced[word];
    setState(() {
      _linkFrom = word;
      _linkFromPt = c;
      _linkToPt = c;
    });
  }

  void _nodePanUpdate(String word, Offset global, Offset delta) {
    if (_linkMode) {
      _linkToPt = _toCanvas(global);
      _coalesceRebuild();
      return;
    }
    final s =
        _pan.value.getMaxScaleOnAxis().clamp(0.3, 2.5);
    if (_customPos.containsKey(word)) {
      _customPos[word] = _customPos[word]! + delta / s;
    } else {
      _drag[word] = (_drag[word] ?? Offset.zero) + delta / s;
    }
    _coalesceRebuild();
  }

  void _nodePanEnd(String word) {
    final wasDragging = _draggingNode != null;
    if (wasDragging) {
      setState(() => _draggingNode = null);
    }
    if (!_linkMode) {
      // Pin the drop spot so the arrangement is kept exactly.
      if (wasDragging) {
        final c = _lastPlaced[word];
        _drag.remove(word);
        if (c != null) {
          setState(() => _customPos[word] = c);
          _persist();
        }
      }
      return;
    }
    final from = _linkFrom;
    final target =
        _linkToPt == null ? null : _bubbleAt(_linkToPt!);
    setState(() {
      _linkFrom = null;
      _linkFromPt = null;
      _linkToPt = null;
    });
    if (from == null || target == null || target == from) return;
    _commitLink(from, target);
  }

  /// Attach two words; the upper bubble becomes the parent.
  Future<void> _commitLink(String a, String b) async {
    final ga = widget.graph.get(a);
    final gb = widget.graph.get(b);
    if (ga == null || gb == null) return;
    if (ga.children.contains(b) || gb.children.contains(a)) {
      _notice('Those two are already linked.');
      return;
    }
    final pa = _lastPlaced[a] ?? Offset.zero;
    final pb = _lastPlaced[b] ?? Offset.zero;
    String parent, child;
    if ((pa.dy - pb.dy).abs() < 12) {
      parent = a;
      child = b; // side by side: drawing direction wins
    } else if (pa.dy < pb.dy) {
      parent = a;
      child = b;
    } else {
      parent = b;
      child = a;
    }
    widget.graph.linkParentChild(parent, child);
    await _persist();
    _notice('"$parent" is now above "$child".');
  }

  void _zoom(double factor) {
    final cur = _pan.value.getMaxScaleOnAxis();
    final target = (cur * factor).clamp(0.3, 2.5);
    final m2 = _pan.value.clone();
    m2.scaleByDouble(target / cur, target / cur, target / cur, 1.0);
    _pan.value = m2;
  }

  Future<void> _addChild() async {
    final sel = _selected;
    final raw = _childCtrl.text.trim().toLowerCase();
    if (sel == null || raw.isEmpty) return;
    widget.graph.ensure(sel);
    widget.graph.ensure(raw);
    widget.graph.linkParentChild(sel, raw);
    _childCtrl.clear();
    await _persist();
  }

  Future<void> _addParent() async {
    final sel = _selected;
    final raw = _parentCtrl.text.trim().toLowerCase();
    if (sel == null || raw.isEmpty) return;
    widget.graph.ensure(sel);
    widget.graph.ensure(raw);
    widget.graph.linkParentChild(raw, sel);
    _parentCtrl.clear();
    await _persist();
  }

  Future<void> _createOrJump() async {
    final raw = _jumpCtrl.text.trim().toLowerCase();
    if (raw.isEmpty) return;
    widget.graph.ensure(raw);
    await _persist();
    _select(raw);
    _jumpCtrl.clear();
  }

  Future<void> _deleteSelected() async {
    final sel = _selected;
    if (sel == null) return;
    widget.graph.deleteWord(sel);
    _selected = null;
    widget.onSelectionChanged?.call(null);
    await _persist();
  }

  Future<void> _unlink(String parent, String child) async {
    widget.graph.unlinkParentChild(parent, child);
    await _persist();
  }

  // ---- Full-forest tidy tree layout ----
  ({List<_Placed> placed, List<_Edge> edges, Size canvas}) _layoutAll() {
    final g = widget.graph;
    final pos = <String, Offset>{};
    final visited = <String>{};
    int slot = 0;
    int maxDepth = 0;

    List<String> kidsOf(String w) {
      final n = g.get(w);
      if (n == null) return const [];
      final list = n.children.toList()..sort();
      return list;
    }

    void place(String w, int depth) {
      if (visited.contains(w)) return;
      visited.add(w);
      maxDepth = math.max(maxDepth, depth);
      final kids = kidsOf(w);
      if (kids.isEmpty) {
        pos[w] = Offset(
            _margin + slot * _slotGap, _margin + depth * _levelGap);
        slot++;
      } else {
        for (final k in kids) {
          place(k, depth + 1);
        }
        final xs = [
          for (final k in kids)
            if (pos.containsKey(k)) pos[k]!.dx
        ];
        final cx = xs.isEmpty
            ? _margin + slot * _slotGap
            : (xs.reduce((a, b) => a + b) / xs.length);
        pos[w] = Offset(cx, _margin + depth * _levelGap);
      }
    }

    // Roots first (no parents on top), then anything left over (cycles).
    final roots = [
      for (final k in g.sortedKeys())
        if ((g.get(k)?.parents.isEmpty ?? true)) k
    ];
    for (final r in roots) {
      place(r, 0);
    }
    for (final k in g.sortedKeys()) {
      if (!visited.contains(k)) place(k, 0);
    }

    // Pinned words stay where the user put them; others follow the auto
    // layout plus small drag nudges.
    final placed = <_Placed>[];
    pos.forEach((w, p) {
      placed.add(
          _Placed(w, _customPos[w] ?? (p + (_drag[w] ?? Offset.zero))));
    });

    // De-collide: no two bubbles may sit on top of each other. Pinned
    // words keep their exact spot; the rest slide straight down until
    // free. The held-while-dragging bubble moves freely and settles on
    // release. Sorted top-to-bottom so the pass is deterministic and
    // the map never jitters between rebuilds.
    placed.sort((a, b) {
      final dy = a.center.dy.compareTo(b.center.dy);
      return dy != 0 ? dy : a.center.dx.compareTo(b.center.dx);
    });
    final occupied = <Rect>[];
    for (final p in placed) {
      if (p.word == _draggingNode) continue;
      var r = _nodeRect(p.center);
      if (!_customPos.containsKey(p.word)) {
        var guard = 0;
        while (occupied.any((o) => o.overlaps(r)) && guard++ < 80) {
          p.center =
              p.center + const Offset(0, GraphViewState._nodeH + 30);
          r = _nodeRect(p.center);
        }
      }
      occupied.add(r);
    }

    final byWord = {for (final p in placed) p.word: p.center};

    // One bendy arrow per parent -> child link, pointing down at the child.
    final edges = <_Edge>[];
    for (final n in g.nodes.values) {
      final pkey = WordGraph.norm(n.name);
      final from = byWord[pkey];
      if (from == null) continue;
      for (final c in n.children) {
        final to = byWord[c];
        if (to == null) continue;
        final f = Offset(from.dx, from.dy + _nodeH / 2);
        final t = Offset(to.dx, to.dy - _nodeH / 2);
        final curve = _edgeCurve(f, t);
        edges.add(_Edge(
            f, t, pkey, c, _cubicAt(f, curve.c1, curve.c2, t, 0.5)));
      }
    }

    var maxRight = 0.0;
    var maxBottom = 0.0;
    for (final p in placed) {
      if (p.center.dx > maxRight) maxRight = p.center.dx;
      if (p.center.dy > maxBottom) maxBottom = p.center.dy;
    }
    final w = math.max(
        2200.0,
        math.max(_margin * 2 + slot * _slotGap, maxRight + _margin));
    final h = math.max(
        1500.0,
        math.max(_margin * 2 + (maxDepth + 1) * _levelGap,
            maxBottom + _margin));
    return (placed: placed, edges: edges, canvas: Size(w, h));
  }

  @override
  Widget build(BuildContext context) {
    final keys = widget.graph.sortedKeys();
    final sel = _selected != null ? widget.graph.get(_selected!) : null;
    final laid = _layoutAll();
    _lastPlaced = {for (final p in laid.placed) p.word: p.center};
    _lastEdges = laid.edges;
    _lastCanvas = laid.canvas;

    return Container(
      color: PaperTheme.paper,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Slim word rail.
          Container(
            width: 208,
            decoration: const BoxDecoration(
              color: PaperTheme.paperDark,
              border: Border(
                  right: BorderSide(color: PaperTheme.lineThin)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: TextField(
                    controller: _jumpCtrl,
                    onSubmitted: (_) => _createOrJump(),
                    style: const TextStyle(
                        color: PaperTheme.ink, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'new / find word…',
                      hintStyle: const TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 12),
                      filled: true,
                      fillColor: PaperTheme.surface,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: const BorderSide(
                            color: PaperTheme.lineThin),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: const BorderSide(
                            color: PaperTheme.lineThin),
                      ),
                      suffixIcon: const Icon(Icons.search,
                          size: 16, color: PaperTheme.inkSoft),
                    ),
                  ),
                ),
                Expanded(
                  child: keys.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'No words yet.\nCreate one above, e.g. eat.',
                            style: TextStyle(
                                color: PaperTheme.inkSoft,
                                fontSize: 12),
                          ),
                        )
                      : ListView.builder(
                          itemCount: keys.length,
                          itemBuilder: (context, i) {
                            final k = keys[i];
                            final active = k == _selected;
                            return InkWell(
                              onTap: () => _select(k),
                              borderRadius: BorderRadius.circular(14),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 7),
                                decoration: BoxDecoration(
                                  color: active
                                      ? PaperTheme.chip
                                      : Colors.transparent,
                                  borderRadius:
                                      BorderRadius.circular(14),
                                ),
                                child: Text(k,
                                    style: TextStyle(
                                      color: PaperTheme.ink,
                                      fontSize: 13,
                                      fontWeight: active
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    )),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          // Mind-map side.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Gentle inspector for the focused word.
                if (sel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: const BoxDecoration(
                      color: PaperTheme.paperDark,
                      border: Border(
                          bottom: BorderSide(
                              color: PaperTheme.lineThin)),
                    ),
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color: PaperTheme.card,
                            border:
                                Border.all(color: PaperTheme.line),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(sel.name,
                              style: const TextStyle(
                                  color: PaperTheme.ink,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700)),
                        ),
                        SizedBox(
                          width: 170,
                          child: _MiniField(
                            controller: _childCtrl,
                            hint: '+ child (goes below)…',
                            onAdd: _addChild,
                          ),
                        ),
                        SizedBox(
                          width: 170,
                          child: _MiniField(
                            controller: _parentCtrl,
                            hint: '+ parent (goes above)…',
                            onAdd: _addParent,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Delete this word',
                          onPressed: _deleteSelected,
                          icon: const Icon(Icons.delete_outline,
                              size: 17,
                              color: PaperTheme.inkSoft),
                        ),
                      ],
                    ),
                  ),
                // Canvas with every word on it.
                Expanded(
                  child: laid.placed.isEmpty
                      ? GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onDoubleTapDown: (_) =>
                              _newWordAnywhere(),
                          child: const Center(
                            child: Text(
                              'Double-click anywhere to plant your first word.',
                              style: TextStyle(
                                  color: PaperTheme.inkSoft,
                                  fontSize: 14),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : LayoutBuilder(
                          builder: (ctx, cons) {
                            if (_pendingCenter != null) {
                              final target = _pendingCenter!;
                              _pendingCenter = null;
                              WidgetsBinding.instance
                                  .addPostFrameCallback((_) {
                                if (mounted) {
                                  _centerOnWord(
                                      target, cons.biggest);
                                }
                              });
                            }
                            return Stack(
                              children: [
                            InteractiveViewer(
                              transformationController: _pan,
                              panEnabled: _draggingNode == null,
                              constrained: false,
                              boundaryMargin:
                                  const EdgeInsets.all(double.infinity),
                              minScale: 0.3,
                              maxScale: 2.5,
                              child: SizedBox(
                                key: _canvasKey,
                                width: laid.canvas.width,
                                height: laid.canvas.height,
                                child: Stack(
                                  children: [
                                    // Empty-space taps pick arrows; double-click plants a word.
                                    Positioned.fill(
                                      child: GestureDetector(
                                        behavior:
                                            HitTestBehavior.opaque,
                                        onTapDown: (d) =>
                                            _canvasTapDown(
                                                d.globalPosition),
                                        onTap: _canvasTap,
                                        onDoubleTapDown: (d) {
                                          final pt = _toCanvas(
                                              d.globalPosition);
                                          if (_bubbleAt(pt) !=
                                              null) {
                                            return; // the bubble handles it
                                          }
                                          _newWordAt(pt);
                                        },
                                        child: Container(
                                            color:
                                                Colors.transparent),
                                      ),
                                    ),
                                    const Positioned.fill(
                                        child: IgnorePointer(
                                            child: _DotGrid())),
                                    IgnorePointer(
                                      child: CustomPaint(
                                        size: laid.canvas,
                                        painter: _BranchPainter(
                                            laid.edges,
                                            tempFrom: _linkFromPt,
                                            tempTo: _linkToPt,
                                            selParent:
                                                _selEdge?.parent,
                                            selChild:
                                                _selEdge?.child),
                                      ),
                                    ),
                                    // Delete chip on the selected arrow.
                                    if (_selEdge != null)
                                      for (final e in laid.edges)
                                        if (e.parent ==
                                                _selEdge!.parent &&
                                            e.child ==
                                                _selEdge!.child)
                                          Positioned(
                                            left: (e.mid.dx - 78)
                                                .clamp(
                                                    8.0,
                                                    (laid.canvas.width -
                                                            164)
                                                        .clamp(
                                                            8.0, 1e6)),
                                            top: (e.mid.dy - 52)
                                                .clamp(8.0, 1e6),
                                            child: GestureDetector(
                                              onTap:
                                                  _deleteSelectedEdge,
                                              child: Container(
                                                width: 156,
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                            horizontal:
                                                                10,
                                                            vertical:
                                                                6),
                                                decoration:
                                                    BoxDecoration(
                                                  color:
                                                      PaperTheme.card,
                                                  border: Border.all(
                                                      color: PaperTheme
                                                          .inkSoft),
                                                  borderRadius:
                                                      BorderRadius
                                                          .circular(
                                                              14),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: const Color(
                                                              0xFF3E3A31)
                                                          .withValues(
                                                              alpha:
                                                                  0.14),
                                                      blurRadius: 8,
                                                      offset:
                                                          const Offset(
                                                              0, 2),
                                                    ),
                                                  ],
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize
                                                          .min,
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        'Delete this link?',
                                                        style:
                                                            const TextStyle(
                                                          color: PaperTheme
                                                              .ink,
                                                          fontSize:
                                                              11,
                                                        ),
                                                        overflow:
                                                            TextOverflow
                                                                .ellipsis,
                                                      ),
                                                    ),
                                                    const Icon(
                                                        Icons
                                                            .delete_outline,
                                                        size: 14,
                                                        color: PaperTheme
                                                            .ink),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                    for (final p in laid.placed)
                                      Positioned(
                                        left: p.center.dx -
                                            _nodeW / 2,
                                        top: p.center.dy -
                                            _nodeH / 2,
                                        child: GestureDetector(
                                          onTap: () => _linkMode
                                              ? _linkTap(p.word)
                                              : _select(p.word),
                                          onDoubleTap: () =>
                                              _quickChild(p.word),
                                          onPanDown: (d) =>
                                              _nodePanDown(p.word,
                                                  d.globalPosition),
                                          onPanUpdate: (d) =>
                                              _nodePanUpdate(
                                                  p.word,
                                                  d.globalPosition,
                                                  d.delta),
                                          onPanEnd: (_) =>
                                              _nodePanEnd(p.word),
                                          onPanCancel: () =>
                                              _nodePanEnd(p.word),
                                          child: _MapNode(
                                            word: p.word,
                                            isCenter:
                                                p.word == _selected,
                                            linkSource:
                                                _linkMode &&
                                                    _linkFrom ==
                                                        p.word,
                                            onUnlink: p.word ==
                                                    _selected
                                                ? null
                                                : () {
                                                    final n = widget
                                                        .graph
                                                        .get(sel?.name ??
                                                            '');
                                                    if (n == null) {
                                                      return;
                                                    }
                                                    if (n.parents.contains(
                                                        p.word)) {
                                                      _unlink(p.word,
                                                          n.name);
                                                    } else if (n
                                                        .children
                                                        .contains(
                                                            p.word)) {
                                                      _unlink(n.name,
                                                          p.word);
                                                    }
                                                  },
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            // Link-mode banner.
                            if (_linkMode)
                              Positioned(
                                top: 10,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: Container(
                                    padding:
                                        const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 7),
                                    decoration: BoxDecoration(
                                      color: PaperTheme.card,
                                      border: Border.all(
                                          color: PaperTheme.line),
                                      borderRadius:
                                          BorderRadius.circular(16),
                                    ),
                                    child: const Text(
                                      'Link mode: drag from one bubble to another · the upper one becomes the parent',
                                      style: TextStyle(
                                          color: PaperTheme.ink,
                                          fontSize: 11),
                                    ),
                                  ),
                                ),
                              ),
                            // Zoom controls + hint.
                            Positioned(
                              right: 12,
                              bottom: 12,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: PaperTheme.surface,
                                  border: Border.all(
                                      color:
                                          PaperTheme.lineThin),
                                  borderRadius:
                                      BorderRadius.circular(18),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: _linkMode
                                          ? 'Done linking'
                                          : 'Draw links between words',
                                      onPressed: _toggleLinkMode,
                                      icon: Icon(Icons.timeline,
                                          size: 16,
                                          color: _linkMode
                                              ? PaperTheme.ink
                                              : PaperTheme
                                                  .inkSoft),
                                    ),
                                    IconButton(
                                      tooltip: 'Zoom out',
                                      onPressed: () =>
                                          _zoom(1 / 1.2),
                                      icon: const Icon(
                                          Icons.remove,
                                          size: 16,
                                          color:
                                              PaperTheme.inkSoft),
                                    ),
                                    IconButton(
                                      tooltip: 'Tidy up + recenter',
                                      onPressed: _resetView,
                                      icon: const Icon(
                                          Icons.center_focus_weak,
                                          size: 16,
                                          color:
                                              PaperTheme.inkSoft),
                                    ),
                                    IconButton(
                                      tooltip: 'Zoom in',
                                      onPressed: () =>
                                          _zoom(1.2),
                                      icon: const Icon(Icons.add,
                                          size: 16,
                                          color:
                                              PaperTheme.inkSoft),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const Positioned(
                              left: 12,
                              bottom: 14,
                              child: Text(
                                'your arrangement auto-saves · click a line to cut it · double-click space: new word · link tool: drag bubble to bubble',
                                style: TextStyle(
                                    color: PaperTheme.inkSoft,
                                    fontSize: 10),
                              ),
                            ),
                          ],
                        );
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final VoidCallback onAdd;
  const _MiniField(
      {required this.controller, required this.hint, required this.onAdd});
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onSubmitted: (_) => onAdd(),
      style: const TextStyle(color: PaperTheme.ink, fontSize: 12),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle:
            const TextStyle(color: PaperTheme.inkSoft, fontSize: 12),
        filled: true,
        fillColor: PaperTheme.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: PaperTheme.lineThin),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: PaperTheme.lineThin),
        ),
      ),
    );
  }
}

/// Soft rounded mind-map bubble.
class _MapNode extends StatelessWidget {
  final String word;
  final bool isCenter;
  final bool linkSource;
  final VoidCallback? onUnlink;
  const _MapNode(
      {required this.word,
      required this.isCenter,
      this.linkSource = false,
      this.onUnlink});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: GraphViewState._nodeW,
      height: GraphViewState._nodeH,
      decoration: BoxDecoration(
        color: linkSource
            ? const Color(0xFFCFC5AB)
            : isCenter
                ? PaperTheme.card
                : const Color(0xFFE4DCC7),
        border: Border.all(
            color: (isCenter || linkSource)
                ? PaperTheme.inkSoft
                : PaperTheme.lineThin,
            width: (isCenter || linkSource) ? 1.6 : 1),
        borderRadius: BorderRadius.circular(21),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF3E3A31).withValues(alpha: 0.10),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Padding(
              padding: EdgeInsets.only(left: onUnlink == null ? 0 : 8),
              child: Text(
                word,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: PaperTheme.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          if (onUnlink != null)
            InkWell(
              onTap: onUnlink,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child:
                    Icon(Icons.close, size: 13, color: PaperTheme.inkSoft),
              ),
            ),
        ],
      ),
    );
  }
}

/// Soft bendy arrows between bubbles, muted like the rest.
class _BranchPainter extends CustomPainter {
  final List<_Edge> edges;

  /// Live line while drawing a link (canvas coords).
  final Offset? tempFrom;
  final Offset? tempTo;

  /// Highlighted (selected) arrow.
  final String? selParent;
  final String? selChild;

  _BranchPainter(this.edges,
      {this.tempFrom, this.tempTo, this.selParent, this.selChild});

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = PaperTheme.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final head = Paint()
      ..color = PaperTheme.inkSoft
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (final e in edges) {
      final selected =
          e.parent == selParent && e.child == selChild;
      final paint = selected
          ? (Paint()
            ..color = PaperTheme.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..strokeCap = StrokeCap.round)
          : line;
      final dy = (e.to.dy - e.from.dy).clamp(24.0, 600.0);
      final c1 = Offset(e.from.dx, e.from.dy + dy * 0.55);
      final c2 = Offset(e.to.dx, e.to.dy - dy * 0.55);
      final path = Path()
        ..moveTo(e.from.dx, e.from.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, e.to.dx, e.to.dy);
      canvas.drawPath(path, paint);
      // Little arrowhead pointing along the curve into the child.
      final tangent =
          math.atan2(e.to.dy - c2.dy, e.to.dx - c2.dx);
      const len = 7.0;
      const spread = 0.5;
      canvas.drawLine(
          e.to,
          e.to -
              Offset(math.cos(tangent - spread) * len,
                  math.sin(tangent - spread) * len),
          head);
      canvas.drawLine(
          e.to,
          e.to -
              Offset(math.cos(tangent + spread) * len,
                  math.sin(tangent + spread) * len),
          head);
    }
    // The line being drawn right now.
    final tf = tempFrom;
    final tt = tempTo;
    if (tf != null && tt != null && (tt - tf).distance > 8) {
      canvas.drawLine(
          tf,
          tt,
          Paint()
            ..color = PaperTheme.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round);
      canvas.drawCircle(
          tt, 3.2, Paint()..color = PaperTheme.ink);
    }
  }

  @override
  bool shouldRepaint(covariant _BranchPainter old) =>
      old.edges != edges ||
      old.tempFrom != tempFrom ||
      old.tempTo != tempTo ||
      old.selParent != selParent ||
      old.selChild != selChild;
}

/// Faint dot grid so the canvas feels like a mind-map board.
class _DotGrid extends StatelessWidget {
  const _DotGrid();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _DotGridPainter());
  }
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = PaperTheme.lineThin.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;
    const step = 44.0;
    for (var x = step; x < size.width; x += step) {
      for (var y = step; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
