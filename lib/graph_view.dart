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

  /// Word to select and scroll to when the view first opens.
  final String? initialWord;

  /// Fires whenever the selected word changes (null when deleted).
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
  final Offset from; // anchor on bubble a's rim
  final Offset to; // anchor on bubble b's rim
  final String a;
  final String b;
  final Offset mid; // curve midpoint, for the delete chip + hit-testing
  _Edge(this.from, this.to, this.a, this.b, this.mid);
}

/// Shared curve math so layout, hit-testing and painting agree.
({Offset c1, Offset c2}) _edgeCurve(Offset from, Offset to) {
  final dx = to.dx - from.dx;
  final dy = to.dy - from.dy;
  if (dx.abs() >= dy.abs()) {
    final spread = dx.abs().clamp(24.0, 600.0);
    final dir = dx >= 0 ? 1.0 : -1.0;
    return (
      c1: Offset(from.dx + dir * spread * 0.55, from.dy),
      c2: Offset(to.dx - dir * spread * 0.55, to.dy),
    );
  }
  final spread = dy.abs().clamp(24.0, 600.0);
  final dir = dy >= 0 ? 1.0 : -1.0;
  return (
    c1: Offset(from.dx, from.dy + dir * spread * 0.55),
    c2: Offset(to.dx, to.dy - dir * spread * 0.55),
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
  final _linkedCtrl = TextEditingController();
  final _jumpCtrl = TextEditingController();

  /// Live search filter for the word rail (never creates words by itself).
  String _filter = '';

  /// Viewport size of the canvas area, for scroll-to-word math.
  Size _viewportSize = Size.zero;

  /// Reused for every name dialog. Never disposed mid-flight: disposing a
  /// dialog controller while its route animates out trips rebuilds that
  /// still reference it (red screen). Disposed once with this state.
  final TextEditingController _nameCtrl = TextEditingController();
  final TransformationController _pan = TransformationController();

  /// Words pinned to an exact canvas spot (double-click placement,
  /// drag drops, tidy results). Null entry = auto-placed this layout.

  /// Grab-point offset kept under the cursor while dragging, so the drop
  /// lands exactly where the pointer is (canvas coords).
  Offset _grabOffset = Offset.zero;

  /// Words pinned to an exact canvas spot (double-click placement).
  final Map<String, Offset> _customPos = {};

  /// Link-drawing mode: drag from one bubble to another to attach them.
  bool _linkMode = false;
  String? _linkFrom;
  Offset? _linkFromPt; // canvas coords, temp line start
  Offset? _linkToPt; // canvas coords, temp line end

  /// Word currently being dragged (canvas panning/zoom locks while set,
  /// so the bubble follows the cursor exactly).
  String? _draggingNode;

  /// Pointer currently driving a node drag (null = none).
  int? _dragPointer;

  /// Selected link (pair of words), shown with a delete chip.
  ({String a, String b})? _selEdge;
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
    _linkedCtrl.dispose();
    _jumpCtrl.dispose();
    _nameCtrl.dispose();
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
      _pendingCenter = _selected; // open scrolled to the word
    }
  }

  /// Word to scroll to once the canvas has laid out (then consumed).
  String? _pendingCenter;

  void _centerOnWord(String word, Size viewport) {
    final c = _lastPlaced[word];
    if (c == null) return;
    _pan.value = Matrix4.translationValues(
      viewport.width / 2 - c.dx,
      viewport.height / 2 - c.dy,
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

  void _select(String word, {bool center = false}) {
    setState(() {
      _selected = WordGraph.norm(word);
      _selEdge = null;
      _linkedCtrl.clear();
      if (center) _pendingCenter = _selected;
    });
    widget.onSelectionChanged?.call(_selected);
  }

  /// Empty-canvas press: remember where, for edge picking on tap release.
  void _canvasTapDown(Offset global) {
    _tapDownPt = _toCanvas(global);
  }

  /// Empty-canvas tap: select the nearest link line, or clear the selection.
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
      _selEdge = best == null ? null : (a: best.a, b: best.b);
    });
  }

  Future<void> _deleteSelectedEdge() async {
    final sel = _selEdge;
    if (sel == null) return;
    widget.graph.disconnect(sel.a, sel.b);
    setState(() => _selEdge = null);
    await _persist();
    _notice('Link removed.');
  }

  /// Test hook: create + place + select + persist, like the dialog flow.
  @visibleForTesting
  Future<void> debugCreateWord(String name, Offset at) async {
    widget.graph.ensure(name);
    setState(() => _customPos[name] = at);
    _select(name);
    await _persist();
  }

  /// Test hooks: canvas coords of a link's midpoint, and canvas->screen.
  @visibleForTesting
  Offset? debugCenter(String word) => _lastPlaced[word];
  @visibleForTesting
  Offset? debugEdgeMid(String a, String b) {
    final x = WordGraph.norm(a);
    final y = WordGraph.norm(b);
    for (final e in _lastEdges) {
      if ((e.a == x && e.b == y) || (e.a == y && e.b == x)) {
        return e.mid;
      }
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
      {required String title,
      required String hint,
      String? initial,
      String okLabel = 'Create'}) async {
    _nameCtrl.text = initial ?? '';
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
          controller: _nameCtrl,
          autofocus: true,
          onSubmitted: (_) => Navigator.of(ctx)
              .pop(_nameCtrl.text.trim().toLowerCase()),
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
                .pop(_nameCtrl.text.trim().toLowerCase()),
            child: Text(okLabel,
                style: const TextStyle(
                    color: PaperTheme.ink,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    // NOTE: _nameCtrl is intentionally NOT disposed here (see field docs).
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

  /// Double-click a bubble: quickly spin off a connected word nearby,
  /// fanned out beside its existing links so nothing overlaps.
  Future<void> _quickChild(String word) async {
    final name = await _askWordName(
        title: 'Connected to "$word"', hint: 'linked with "$word"…');
    if (name == null || !mounted) return;
    widget.graph.ensure(name);
    widget.graph.connect(word, name);
    final sibs = widget.graph.neighborsOf(word);
    final i = sibs.indexOf(name).clamp(0, 1 << 30);
    final pc = _lastPlaced[word] ?? const Offset(500, 300);
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

  // ---- Canvas-wide pointer drag ----
  // A front translucent Listener (see build) feeds every press/move here.
  // Unlike gesture recognizers it never loses to the viewer's pan in the
  // arena. Positions are absolute (pointer point + grab offset), so the
  // grabbed spot stays glued under the cursor and the drop lands exactly
  // where the pointer is — no drift math at all.
  void _pointerDown(PointerDownEvent e) {
    if (_dragPointer != null) _abandonDrag(); // heal any stuck drag
    final at = _toCanvas(e.position);
    final word = _bubbleAt(at);
    if (word == null) return; // empty space: viewer pans normally
    _dragPointer = e.pointer;
    _grabOffset = (_lastPlaced[word] ?? at) - at;
    // Lock the viewer before the first move event arrives.
    setState(() => _draggingNode = word);
    if (_linkMode) {
      final c = _lastPlaced[word];
      _linkFrom = word;
      _linkFromPt = c;
      _linkToPt = c;
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (e.pointer != _dragPointer || _draggingNode == null) return;
    final word = _draggingNode!;
    if (_linkMode) {
      _linkToPt = _toCanvas(e.position);
      _coalesceRebuild();
      return;
    }
    _customPos[word] = _toCanvas(e.position) + _grabOffset;
    _coalesceRebuild();
  }

  void _pointerUp(PointerEvent e) {
    if (e.pointer != _dragPointer) return;
    final word = _draggingNode;
    _dragPointer = null;
    if (!_linkMode) {
      // Pin the exact pointer spot so the drop is kept precisely.
      if (word != null) {
        final c = _toCanvas(e.position) + _grabOffset;
        setState(() {
          _draggingNode = null;
          _customPos[word] = c;
        });
        _persist();
      }
      return;
    }
    final from = _linkFrom;
    final target =
        _linkToPt == null ? null : _bubbleAt(_linkToPt!);
    setState(() {
      _draggingNode = null;
      _linkFrom = null;
      _linkFromPt = null;
      _linkToPt = null;
    });
    if (from == null || target == null || target == from) return;
    _commitLink(from, target);
  }

  /// Drop a stuck drag safely (e.g. pointer left the window mid-drag).
  void _abandonDrag() {
    final word = _draggingNode;
    if (word != null && _lastPlaced.containsKey(word)) {
      _customPos[word] = _lastPlaced[word]!;
    }
    _dragPointer = null;
    _draggingNode = null;
    _linkFrom = null;
    _linkFromPt = null;
    _linkToPt = null;
  }

  /// Draw a plain undirected link between two words.
  Future<void> _commitLink(String a, String b) async {
    if (widget.graph.get(a) == null || widget.graph.get(b) == null) {
      return;
    }
    if (widget.graph.linked(a, b)) {
      _notice('Those two are already linked.');
      return;
    }
    widget.graph.connect(a, b);
    await _persist();
    _notice('"$a" and "$b" are now linked.');
  }

  void _zoom(double factor) {
    final cur = _pan.value.getMaxScaleOnAxis();
    final target = (cur * factor).clamp(0.3, 2.5);
    final m2 = _pan.value.clone();
    m2.scaleByDouble(target / cur, target / cur, target / cur, 1.0);
    _pan.value = m2;
  }

  Future<void> _addLinked() async {
    final sel = _selected;
    final raw = _linkedCtrl.text.trim().toLowerCase();
    if (sel == null || raw.isEmpty) return;
    widget.graph.ensure(sel);
    widget.graph.ensure(raw);
    widget.graph.connect(sel, raw);
    final sibs = widget.graph.neighborsOf(sel);
    final i = sibs.indexOf(raw).clamp(0, 1 << 30);
    final pc = _lastPlaced[sel] ?? const Offset(500, 300);
    setState(() {
      _customPos[raw] = Offset(
        pc.dx + (i - (sibs.length - 1) / 2) * _slotGap,
        pc.dy + _levelGap,
      );
    });
    _linkedCtrl.clear();
    await _persist();
  }

  /// Search submit: jump to the exact word, else the first match.
  /// Only creates when nothing matches at all.
  Future<void> _jumpSubmit() async {
    final raw = _jumpCtrl.text.trim().toLowerCase();
    if (raw.isEmpty) return;
    final matches = _filteredKeys();
    final exact = [for (final k in matches) if (k == raw) k];
    if (exact.isNotEmpty) {
      _select(exact.first, center: true);
    } else if (matches.isNotEmpty) {
      _select(matches.first, center: true);
    } else {
      await _createWord(raw, nearView: true);
    }
  }

  /// Explicit creation (never implied by searching).
  Future<void> _createWord(String raw, {bool nearView = false}) async {
    final name = raw.trim().toLowerCase();
    if (name.isEmpty) return;
    final isNew = widget.graph.get(name) == null;
    widget.graph.ensure(name);
    if (isNew) {
      final at = nearView ? _viewCenterCanvas() : null;
      if (at != null) {
        setState(() => _customPos[name] = at);
      }
      _notice('"$name" created.');
    }
    _jumpCtrl.clear();
    setState(() => _filter = '');
    _select(name, center: true);
    await _persist();
  }

  /// Canvas point currently at the middle of the viewport.
  Offset _viewCenterCanvas() {
    final s = _pan.value.getMaxScaleOnAxis().clamp(0.3, 2.5);
    final t = _pan.value.getTranslation();
    final vw = _viewportSize.width;
    final vh = _viewportSize.height;
    if (vw <= 0 || vh <= 0) return const Offset(600, 500);
    return Offset((vw / 2 - t.x) / s, (vh / 2 - t.y) / s);
  }

  List<String> _filteredKeys() {
    final keys = widget.graph.sortedKeys();
    final f = _filter.trim().toLowerCase();
    if (f.isEmpty) return keys;
    final starts = [
      for (final k in keys)
        if (k.startsWith(f)) k
    ];
    final contains = [
      for (final k in keys)
        if (!k.startsWith(f) && k.contains(f)) k
    ];
    return [...starts, ...contains];
  }

  Future<void> _deleteSelected() async {
    final sel = _selected;
    if (sel == null) return;
    widget.graph.deleteWord(sel);
    _selected = null;
    widget.onSelectionChanged?.call(null);
    await _persist();
  }

  static const List<int> _palette = [
    0xFFE4DCC7, // paper (default)
    0xFFCBCFAE, // sage
    0xFFD9C69E, // sand
    0xFFD3B3A4, // clay
    0xFFB9C2C6, // slate
    0xFFD6BFC2, // blush
  ];

  Color _nodeColor(String word) {
    final c = widget.graph.get(word)?.color;
    if (c == null) return const Color(0xFFE4DCC7);
    return Color(c);
  }

  Future<void> _renameSelected() async {
    final sel = _selected;
    if (sel == null) return;
    final name = await _askWordName(
        title: 'Rename "$sel"',
        hint: 'new name…',
        initial: sel,
        okLabel: 'Rename');
    if (name == null || !mounted) return;
    if (!widget.graph.rename(sel, name)) {
      _notice('Could not rename — name taken or invalid.');
      return;
    }
    setState(() {
      final spot = _customPos.remove(sel);
      if (spot != null) _customPos[name] = spot;
      _selected = name;
    });
    await _persist();
  }

  void _setColor(int? color) {
    final sel = _selected;
    if (sel == null) return;
    widget.graph.get(sel)?.color = color;
    setState(() {});
    _persist();
  }

  // ---- Free-canvas layout ----
  // Saved spots win. Words never placed before cascade out from the
  // middle in reading order; the pass below keeps them from overlapping.
  // Nothing here ever moves a pinned word.
  ({List<_Placed> placed, List<_Edge> edges, Size canvas}) _layoutAll() {
    final g = widget.graph;
    final pos = <String, Offset>{};
    var i = 0;
    for (final k in g.sortedKeys()) {
      if (_customPos.containsKey(k)) continue;
      pos[k] = Offset(
        320 + (i % 5) * 230,
        260 + (i ~/ 5) * 160,
      );
      i++;
    }

    // Pinned words stay where the user put them; others follow the auto
    // layout.
    final placed = <_Placed>[];
    pos.forEach((w, p) {
      placed.add(_Placed(w, _customPos[w] ?? p));
    });
    for (final e in _customPos.entries) {
      if (g.nodes.containsKey(e.key) && !pos.containsKey(e.key)) {
        placed.add(_Placed(e.key, e.value));
      }
    }

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

    // One plain link line per connection (undirected, each pair once).
    final edges = <_Edge>[];
    for (final n in g.nodes.values) {
      final akey = WordGraph.norm(n.name);
      final from = byWord[akey];
      if (from == null) continue;
      for (final c in n.links) {
        if (akey.compareTo(c) >= 0) continue; // draw each pair once
        final to = byWord[c];
        if (to == null) continue;
        // Anchor on facing sides so lines leave bubbles cleanly.
        final bool sideBySide =
            (to.dx - from.dx).abs() >= (to.dy - from.dy).abs();
        final Offset f;
        final Offset t;
        if (sideBySide && to.dx >= from.dx) {
          f = Offset(from.dx + _nodeW / 2, from.dy);
          t = Offset(to.dx - _nodeW / 2, to.dy);
        } else if (sideBySide) {
          f = Offset(from.dx - _nodeW / 2, from.dy);
          t = Offset(to.dx + _nodeW / 2, to.dy);
        } else if (to.dy >= from.dy) {
          f = Offset(from.dx, from.dy + _nodeH / 2);
          t = Offset(to.dx, to.dy - _nodeH / 2);
        } else {
          f = Offset(from.dx, from.dy - _nodeH / 2);
          t = Offset(to.dx, to.dy + _nodeH / 2);
        }
        final curve = _edgeCurve(f, t);
        edges.add(_Edge(
            f, t, akey, c, _cubicAt(f, curve.c1, curve.c2, t, 0.5)));
      }
    }

    var maxRight = 0.0;
    var maxBottom = 0.0;
    for (final p in placed) {
      if (p.center.dx > maxRight) maxRight = p.center.dx;
      if (p.center.dy > maxBottom) maxBottom = p.center.dy;
    }
    final w = math.max(2200.0, maxRight + _margin);
    final h = math.max(1500.0, maxBottom + _margin);
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
    final shown = _filteredKeys();
    final typed = _jumpCtrl.text.trim().toLowerCase();
    final showCreateRow =
        typed.isNotEmpty && widget.graph.get(typed) == null;

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
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('graph-search'),
                          controller: _jumpCtrl,
                          onChanged: (_) =>
                              setState(() => _filter = _jumpCtrl.text),
                          onSubmitted: (_) => _jumpSubmit(),
                          style: const TextStyle(
                              color: PaperTheme.ink, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'find a word…',
                            hintStyle: const TextStyle(
                                color: PaperTheme.inkSoft,
                                fontSize: 12),
                            filled: true,
                            fillColor: PaperTheme.surface,
                            contentPadding:
                                const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(18),
                              borderSide: const BorderSide(
                                  color: PaperTheme.lineThin),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(18),
                              borderSide: const BorderSide(
                                  color: PaperTheme.lineThin),
                            ),
                            suffixIcon: _filter.isEmpty
                                ? const Icon(Icons.search,
                                    size: 16,
                                    color: PaperTheme.inkSoft)
                                : InkWell(
                                    onTap: () {
                                      _jumpCtrl.clear();
                                      setState(
                                          () => _filter = '');
                                    },
                                    borderRadius:
                                        BorderRadius.circular(12),
                                    child: const Icon(Icons.close,
                                        size: 15,
                                        color: PaperTheme.inkSoft),
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Create a new word here',
                        onPressed: () async {
                          final name = await _askWordName(
                              title: 'New word',
                              hint: 'e.g. snack');
                          if (name == null || !mounted) return;
                          await _createWord(name, nearView: true);
                        },
                        icon: const Icon(Icons.add,
                            size: 18, color: PaperTheme.ink),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: keys.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'No words yet.\nCreate one with + above, e.g. eat.',
                            style: TextStyle(
                                color: PaperTheme.inkSoft,
                                fontSize: 12),
                          ),
                        )
                      : ListView.builder(
                          itemCount:
                              shown.length + (showCreateRow ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (showCreateRow && i == shown.length) {
                              return InkWell(
                                onTap: () => _createWord(typed,
                                    nearView: true),
                                borderRadius:
                                    BorderRadius.circular(14),
                                child: Container(
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: PaperTheme.chip,
                                    borderRadius:
                                        BorderRadius.circular(14),
                                  ),
                                  child: Text('+ Create "$typed"',
                                      style: const TextStyle(
                                        color: PaperTheme.ink,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      )),
                                ),
                              );
                            }
                            final k = shown[i];
                            final active = k == _selected;
                            return InkWell(
                              onTap: () =>
                                  _select(k, center: true),
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
                // Inspector for the selected word.
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
                            color: _nodeColor(sel.name),
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
                        IconButton(
                          tooltip: 'Rename',
                          onPressed: _renameSelected,
                          icon: const Icon(Icons.edit_outlined,
                              size: 17,
                              color: PaperTheme.inkSoft),
                        ),
                        // Card color dots.
                        for (final c in _palette)
                          InkWell(
                            onTap: () => _setColor(
                                c == _palette.first ? null : c),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: Color(c),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: sel.color == c ||
                                          (sel.color == null &&
                                              c == _palette.first)
                                      ? PaperTheme.ink
                                      : PaperTheme.lineThin,
                                  width: sel.color == c ||
                                          (sel.color == null &&
                                              c == _palette.first)
                                      ? 2
                                      : 1,
                                ),
                              ),
                            ),
                          ),
                        SizedBox(
                          width: 190,
                          child: _MiniField(
                            controller: _linkedCtrl,
                            hint: '+ linked word…',
                            onAdd: _addLinked,
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
                            _viewportSize = cons.biggest;
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
                              scaleEnabled: _draggingNode == null,
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
                                            selA: _selEdge?.a,
                                            selB: _selEdge?.b),
                                      ),
                                    ),
                                    // Delete chip on the selected link.
                                    if (_selEdge != null)
                                      for (final e in laid.edges)
                                        if ((e.a == _selEdge!.a &&
                                                e.b == _selEdge!.b) ||
                                            (e.a == _selEdge!.b &&
                                                e.b == _selEdge!.a))
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
                                          // Taps select / drill; all dragging
                                          // is driven by the canvas pointer
                                          // layer so bubbles never lose a drag.
                                          onTap: () => _linkMode
                                              ? _linkTap(p.word)
                                              : _select(p.word),
                                          onDoubleTap: () =>
                                              _quickChild(p.word),
                                          child: _MapNode(
                                            word: p.word,
                                            fill: _nodeColor(p.word),
                                            isCenter:
                                                p.word == _selected,
                                            linkSource:
                                                _linkMode &&
                                                    _linkFrom ==
                                                        p.word,
                                          ),
                                        ),
                                      ),
                                    // Front drag layer: feeds every press and
                                    // move straight to the drag logic, immune
                                    // to gesture-arena fights, while letting
                                    // taps fall through to bubbles beneath.
                                    Positioned.fill(
                                      child: Listener(
                                        behavior:
                                            HitTestBehavior.translucent,
                                        onPointerDown: _pointerDown,
                                        onPointerMove: _pointerMove,
                                        onPointerUp: _pointerUp,
                                        onPointerCancel: _pointerUp,
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
                                      'Link mode: drag from one bubble to another to link them',
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
                                'drag bubbles to arrange (they stay) · click a line to cut it · double-click space: new word · link tool: drag bubble to bubble',
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
  final Color fill;
  final bool isCenter;
  final bool linkSource;
  const _MapNode(
      {required this.word,
      required this.fill,
      required this.isCenter,
      this.linkSource = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: GraphViewState._nodeW,
      height: GraphViewState._nodeH,
      decoration: BoxDecoration(
        color: linkSource ? const Color(0xFFCFC5AB) : fill,
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
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
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
    );
  }
}

/// Soft bendy link lines between bubbles, muted like the rest.
class _BranchPainter extends CustomPainter {
  final List<_Edge> edges;

  /// Live line while drawing a link (canvas coords).
  final Offset? tempFrom;
  final Offset? tempTo;

  /// Highlighted (selected) link.
  final String? selA;
  final String? selB;

  _BranchPainter(this.edges,
      {this.tempFrom, this.tempTo, this.selA, this.selB});

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = PaperTheme.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (final e in edges) {
      final selected = (e.a == selA && e.b == selB) ||
          (e.a == selB && e.b == selA);
      final paint = selected
          ? (Paint()
            ..color = PaperTheme.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round)
          : line;
      final c = _edgeCurve(e.from, e.to);
      final path = Path()
        ..moveTo(e.from.dx, e.from.dy)
        ..cubicTo(
            c.c1.dx, c.c1.dy, c.c2.dx, c.c2.dy, e.to.dx, e.to.dy);
      canvas.drawPath(path, paint);
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
      old.selA != selA ||
      old.selB != selB;
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
