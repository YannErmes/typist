import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

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
  double w;
  double h;
  _Placed(this.word, this.center, {this.w = 148, this.h = 42});
}

class _Edge {
  final Offset from; // anchor on bubble a's rim
  final Offset to; // anchor on bubble b's rim
  final String a;
  final String b;
  final Offset mid; // curve midpoint, for the delete chip + hit-testing
  final String? jump; // numbered jump-link, or null for a solid line
  _Edge(this.from, this.to, this.a, this.b, this.mid, {this.jump});
}

const _jumpLabelStyle = TextStyle(
    color: PaperTheme.ink, fontSize: 11, fontWeight: FontWeight.w700);

/// Pill rect for a jump number, identical for painting and hit-testing.
RRect _jumpBadgeRect(Offset tip, String label) {
  final tp = TextPainter(
    text: TextSpan(text: label, style: _jumpLabelStyle),
    textDirection: TextDirection.ltr,
  )..layout();
  final rect = RRect.fromRectAndRadius(
    Rect.fromCenter(
        center: tip,
        width: tp.width + 16,
        height: tp.height + 9),
    const Radius.circular(9),
  );
  tp.dispose();
  return rect;
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
  if (e.jump != null) return _distToJumpEdge(pt, e);
  final c = _edgeCurve(e.from, e.to);
  var best = double.infinity;
  for (var i = 0; i <= 24; i++) {
    final p = _cubicAt(e.from, c.c1, c.c2, e.to, i / 24);
    final d = (p - pt).distance;
    if (d < best) best = d;
  }
  return best;
}

/// Short stub pointing TOWARD the partner word, so each number chip
/// sits on the side facing its connection (a direction indicator that
/// swings as bubbles move). Badge tip + direction of travel.
({Offset tip, Offset dir}) _jumpStub(Offset anchor, Offset partner) {
  var d = Offset(partner.dx - anchor.dx, partner.dy - anchor.dy);
  if (d.distance < 1) d = const Offset(0, 1);
  final dir = d / d.distance;
  return (tip: anchor + dir * 34, dir: dir);
}

double _distToSegment(Offset p, Offset a, Offset b) {
  final abx = b.dx - a.dx;
  final aby = b.dy - a.dy;
  final denom = abx * abx + aby * aby;
  var t = denom <= 0
      ? 0.0
      : ((p.dx - a.dx) * abx + (p.dy - a.dy) * aby) / denom;
  t = t.clamp(0.0, 1.0);
  return Offset(p.dx - (a.dx + abx * t), p.dy - (a.dy + aby * t))
      .distance;
}

double _distToJumpEdge(Offset pt, _Edge e) {
  var best = double.infinity;
  for (final ends in [(e.from, e.to), (e.to, e.from)]) {
    final s = _jumpStub(ends.$1, ends.$2);
    final dLine = _distToSegment(pt, ends.$1, s.tip);
    if (dLine < best) best = dLine;
    final dBadge = (pt - s.tip).distance;
    if (dBadge < best) best = dBadge;
  }
  return best;
}

/// Bubble footprint plus breathing room, used for overlap checks.
Rect _nodeRect(Offset c, [Size s = const Size(148, 42)]) =>
    Rect.fromCenter(
      center: c,
      width: s.width + 24,
      height: s.height + 30,
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
  Map<String, Size> _lastSizes = {};
  List<_Edge> _lastEdges = [];
  final GlobalKey _canvasKey = GlobalKey();

  static const double _nodeW = 148;
  static const double _nodeH = 42;
  static const double _picW = 150;
  static const double _picH = 118;
  static const double _slotGap = 196;
  static const double _levelGap = 148;
  static const double _margin = 140;

  /// The board is unbounded: words live anywhere finite, and the place
  /// grows whichever way they are dragged. Only NaN/inf (corrupt saves)
  /// get pulled back near the origin.
  static Offset _sanitize(Offset p) => Offset(
        p.dx.isFinite ? p.dx.clamp(-1e6, 1e6).toDouble() : 500.0,
        p.dy.isFinite ? p.dy.clamp(-1e6, 1e6).toDouble() : 300.0,
      );

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
    // Corrupt spots are pulled back near the origin.
    for (final n in widget.graph.nodes.values) {
      if (n.hasPos && n.x!.isFinite && n.y!.isFinite) {
        _customPos[WordGraph.norm(n.name)] =
            _sanitize(Offset(n.x!, n.y!));
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

  /// Empty-canvas tap: a number chip flies to its group, else select
  /// the nearest link line, else clear the selection.
  void _canvasTap() {
    final pt = _tapDownPt;
    _tapDownPt = null;
    if (pt == null || _linkMode) return;
    if (_bubbleAt(pt) != null) return; // the bubble's own tap handles it
    // Number chips first (exact pill shape): fly to the next word
    // sharing the number.
    for (final e in _lastEdges) {
      if (e.jump == null) continue;
      final sa = _jumpStub(e.from, e.to);
      if (_jumpBadgeRect(sa.tip, e.jump!)
          .outerRect
          .inflate(5)
          .contains(pt)) {
        _jumpNavigate(e, e.a);
        return;
      }
      final sb = _jumpStub(e.to, e.from);
      if (_jumpBadgeRect(sb.tip, e.jump!)
          .outerRect
          .inflate(5)
          .contains(pt)) {
        _jumpNavigate(e, e.b);
        return;
      }
    }
    final best = _nearestEdge(pt);
    setState(() {
      _selEdge = best == null ? null : (a: best.a, b: best.b);
    });
  }

  /// Nearest link line to a canvas point, if close enough to grab.
  _Edge? _nearestEdge(Offset pt) {
    // Generous, zoom-aware grab radius so lines stay tappable when zoomed out.
    final scale =
        _pan.value.getMaxScaleOnAxis().clamp(0.05, 2.5);
    _Edge? best;
    var bestD = 30.0 / scale;
    for (final e in _lastEdges) {
      final d = _distToEdge(pt, e);
      if (d < bestD) {
        bestD = d;
        best = e;
      }
    }
    return best;
  }

  /// Fly to the next word carrying [edge]'s jump number, cycling through
  /// the whole group (1st -> 2nd -> 3rd -> back to 1st).
  void _jumpNavigate(_Edge edge, String fromWord) {
    final number = edge.jump;
    if (number == null) return;
    final group = <String>[];
    for (final entry in widget.graph.nodes.entries) {
      if (entry.value.jumps.values.any((v) => v == number)) {
        group.add(entry.key);
      }
    }
    group.sort();
    if (group.isEmpty) return;
    String next = edge.a == WordGraph.norm(fromWord) ? edge.b : edge.a;
    final i = group.indexOf(WordGraph.norm(fromWord));
    if (i >= 0 && group.length > 1) {
      next = group[(i + 1) % group.length];
    }
    _select(next);
    _pendingCenter = WordGraph.norm(next);
    setState(() {});
    _notice('Jump $number shows "$next".');
  }

  /// Next free jump number (max used + 1, or 1).
  String _suggestJumpNumber() {
    var maxN = 0;
    for (final n in widget.graph.nodes.values) {
      for (final v in n.jumps.values) {
        final parsed = int.tryParse(v.trim());
        if (parsed != null && parsed > maxN) maxN = parsed;
      }
    }
    return '${maxN + 1}';
  }

  /// Double-clicked a line: turn it into a numbered jump (or renumber).
  Future<void> _jumpDialog(String a, String b) async {
    final current = widget.graph.jumpNumber(a, b);
    final num = await _askWordName(
      title: current == null
          ? 'Jump "$a" to "$b"'
          : 'Jump $current: "$a" to "$b"',
      hint: 'number, e.g. ${_suggestJumpNumber()}',
      initial: current,
      okLabel: 'Make jump',
    );
    if (num == null || !mounted) return;
    widget.graph.setJump(a, b, num);
    setState(() => _selEdge = (a: a, b: b));
    await _persist();
    _notice('Jump $num: connected without a line.');
  }

  Future<void> _unsjump(String a, String b) async {
    widget.graph.setJump(a, b, null);
    await _persist();
    _notice('Back to a solid line.');
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
  double debugScale() => _pan.value.getMaxScaleOnAxis();
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

  Size _nodeSize(String word) {
    final n = widget.graph.get(word);
    if (n != null && n.hasImage) {
      return const Size(_picW, _picH);
    }
    return const Size(_nodeW, _nodeH);
  }

  /// Which bubble contains this canvas point, if any.
  String? _bubbleAt(Offset pt) {
    for (final e in _lastPlaced.entries) {
      final c = e.value;
      final s = _lastSizes[e.key] ?? const Size(_nodeW, _nodeH);
      if ((pt.dx - c.dx).abs() <= s.width / 2 + 8 &&
          (pt.dy - c.dy).abs() <= s.height / 2 + 8) {
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
      _customPos[name] = _sanitize(scene);
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
        final c = _sanitize(_toCanvas(e.position) + _grabOffset);
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
    final target = (cur * factor).clamp(0.05, 2.5);
    final m2 = _pan.value.clone();
    m2.scaleByDouble(target / cur, target / cur, target / cur, 1.0);
    _pan.value = m2;
  }

  /// Fit button: center the whole map and show as much of it as possible.
  /// Huge spreads zoom out deep (never below readability's basement);
  /// whatever still overflows is cropped around the centered middle.
  void _fitView() {
    if (_lastPlaced.isEmpty) return;
    final vw = _viewportSize.width;
    final vh = _viewportSize.height;
    if (vw <= 0 || vh <= 0) return;
    var minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9;
    for (final c in _lastPlaced.values) {
      if (c.dx < minX) minX = c.dx;
      if (c.dy < minY) minY = c.dy;
      if (c.dx > maxX) maxX = c.dx;
      if (c.dy > maxY) maxY = c.dy;
    }
    const pad = 140.0;
    final bw = math.max(200.0, maxX - minX + pad * 2);
    final bh = math.max(200.0, maxY - minY + pad * 2);
    final s = (math.min(vw / bw, vh / bh)).clamp(0.05, 1.0);
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    final base = Matrix4.translationValues(
        vw / 2 - cx * s, vh / 2 - cy * s, 0.0);
    final m = base..scaleByDouble(s, s, s, 1.0);
    setState(() => _pan.value = m);
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

  /// Add a picture node: behaves like a word (drag, link, delete),
  /// but shows an image. Source is a local file or a web link.
  Future<void> _addPicture() async {
    final src = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF4EEDF),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('Picture from…',
            style: TextStyle(
                color: PaperTheme.ink,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open,
                  color: PaperTheme.inkSoft),
              title: const Text('A file on this device',
                  style: TextStyle(color: PaperTheme.ink)),
              onTap: () => Navigator.of(ctx).pop('file'),
            ),
            ListTile(
              leading: const Icon(Icons.link,
                  color: PaperTheme.inkSoft),
              title: const Text('A web link',
                  style: TextStyle(color: PaperTheme.ink)),
              onTap: () => Navigator.of(ctx).pop('link'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: PaperTheme.inkSoft)),
          ),
        ],
      ),
    );
    if (src == null || !mounted) return;
    String? ref;
    if (src == 'file') {
      try {
        final picked = await ImagePicker()
            .pickImage(source: ImageSource.gallery);
        if (picked == null) return;
        if (kIsWeb) {
          final bytes = await picked.readAsBytes();
          final key =
              'mem:${DateTime.now().millisecondsSinceEpoch}';
          setState(() => _memImages[key] = bytes);
          ref = key;
        } else {
          ref = await widget.storage.importImageFile(picked.path);
          if (ref == null || !mounted) {
            _notice('Could not copy that file.');
            return;
          }
        }
      } catch (_) {
        if (mounted) _notice('Could not pick that file.');
        return;
      }
    } else {
      final url = await _askUrl();
      if (url == null || !mounted) return;
      ref = url;
    }
    final name = await _askWordName(
        title: 'Name this picture', hint: 'e.g. sunset');
    if (name == null || !mounted) return;
    final node = widget.graph.ensure(name);
    node.image = ref;
    setState(() => _customPos[name] = _viewCenterCanvas());
    _select(name, center: true);
    await _persist();
    _notice('Picture "$name" on the map — link it like any word.');
  }

  /// Ask for an image URL (kept verbatim: links are case-sensitive).
  /// Uses the shared persistent controller (see _nameCtrl docs).
  Future<String?> _askUrl() async {
    _nameCtrl.clear();
    final field = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: PaperTheme.lineThin),
    );
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF4EEDF),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('Image link',
            style: TextStyle(
                color: PaperTheme.ink,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        content: TextField(
          controller: _nameCtrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          onSubmitted: (_) =>
              Navigator.of(ctx).pop(_nameCtrl.text.trim()),
          style:
              const TextStyle(color: PaperTheme.ink, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'https://…',
            hintStyle: const TextStyle(
                color: PaperTheme.inkSoft, fontSize: 13),
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
            onPressed: () =>
                Navigator.of(ctx).pop(_nameCtrl.text.trim()),
            child: const Text('Use link',
                style: TextStyle(
                    color: PaperTheme.ink,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty) return null;
    return url.trim();
  }

  /// Canvas point currently at the middle of the viewport.
  Offset _viewCenterCanvas() {
    final s = _pan.value.getMaxScaleOnAxis().clamp(0.05, 2.5);
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

  /// Keep the word, drop only its picture.
  Future<void> _removePicture() async {
    final sel = _selected;
    final node = sel == null ? null : widget.graph.get(sel);
    if (node == null) return;
    node.image = null;
    await _persist();
    _notice('Picture removed — "$sel" stays as a word.');
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

  /// In-memory bytes for web-picked pictures (`mem:` refs).
  final Map<String, Uint8List> _memImages = {};

  /// Picture for a node, or null for plain word bubbles.
  Widget? _nodePicture(String word) {
    final ref = widget.graph.get(word)?.image?.trim();
    if (ref == null || ref.isEmpty) return null;
    if (ref.startsWith('http://') || ref.startsWith('https://')) {
      return Image.network(ref,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _brokenPicture());
    }
    if (ref.startsWith('mem:')) {
      final bytes = _memImages[ref];
      if (bytes == null) return _brokenPicture();
      return Image.memory(bytes,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _brokenPicture());
    }
    final path = widget.storage.resolveImage(ref);
    if (path == null) return _brokenPicture();
    return Image.file(File(path),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            _brokenPicture());
  }

  Widget _brokenPicture() {
    return const ColoredBox(
      color: Color(0xFFD6CDB4),
      child: Center(
        child: Icon(Icons.broken_image_outlined,
            color: PaperTheme.inkSoft),
      ),
    );
  }

  Future<void> _editMeaning() async {
    final sel = _selected;
    final node = sel == null ? null : widget.graph.get(sel);
    if (node == null) return;
    _nameCtrl.text = node.meaning ?? '';
    final field = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: PaperTheme.lineThin),
    );
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF4EEDF),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Text('Meaning of "${node.name}"',
            style: const TextStyle(
                color: PaperTheme.ink,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: _nameCtrl,
            autofocus: true,
            maxLines: 4,
            minLines: 2,
            style:
                const TextStyle(color: PaperTheme.ink, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'What does it mean…',
              hintStyle: const TextStyle(
                  color: PaperTheme.inkSoft, fontSize: 13),
              filled: true,
              fillColor: PaperTheme.surface,
              border: field,
              enabledBorder: field,
              focusedBorder: field,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: PaperTheme.inkSoft)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(_nameCtrl.text.trim()),
            child: const Text('Save',
                style: TextStyle(
                    color: PaperTheme.ink,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (saved == null || !mounted) return;
    node.meaning = saved.isEmpty ? null : saved;
    setState(() {});
    await _persist();
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
      final s = _nodeSize(w);
      placed.add(_Placed(w, _customPos[w] ?? p, w: s.width, h: s.height));
    });
    for (final e in _customPos.entries) {
      if (g.nodes.containsKey(e.key) && !pos.containsKey(e.key)) {
        final s = _nodeSize(e.key);
        placed.add(_Placed(e.key, e.value, w: s.width, h: s.height));
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
      var r = _nodeRect(p.center, Size(p.w, p.h));
      if (!_customPos.containsKey(p.word)) {
        var guard = 0;
        while (occupied.any((o) => o.overlaps(r)) && guard++ < 80) {
          p.center =
              p.center + const Offset(0, GraphViewState._nodeH + 30);
          r = _nodeRect(p.center, Size(p.w, p.h));
        }
      }
      occupied.add(r);
    }

    final byWord = {for (final p in placed) p.word: p.center};
    final bySize = {
      for (final p in placed) p.word: Size(p.w, p.h)
    };

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
        final sa = bySize[akey] ?? const Size(_nodeW, _nodeH);
        final sb = bySize[c] ?? const Size(_nodeW, _nodeH);
        // Anchor on facing sides so lines leave bubbles cleanly.
        final bool sideBySide =
            (to.dx - from.dx).abs() >= (to.dy - from.dy).abs();
        final Offset f;
        final Offset t;
        if (sideBySide && to.dx >= from.dx) {
          f = Offset(from.dx + sa.width / 2, from.dy);
          t = Offset(to.dx - sb.width / 2, to.dy);
        } else if (sideBySide) {
          f = Offset(from.dx - sa.width / 2, from.dy);
          t = Offset(to.dx + sb.width / 2, to.dy);
        } else if (to.dy >= from.dy) {
          f = Offset(from.dx, from.dy + sa.height / 2);
          t = Offset(to.dx, to.dy - sb.height / 2);
        } else {
          f = Offset(from.dx, from.dy - sa.height / 2);
          t = Offset(to.dx, to.dy + sb.height / 2);
        }
        final curve = _edgeCurve(f, t);
        edges.add(_Edge(f, t, akey, c,
            _cubicAt(f, curve.c1, curve.c2, t, 0.5),
            jump: g.jumpNumber(akey, c)));
      }
    }

    var minX = 1e9, minY = 1e9, maxRight = -1e9, maxBottom = -1e9;
    for (final p in placed) {
      if (p.center.dx < minX) minX = p.center.dx;
      if (p.center.dy < minY) minY = p.center.dy;
      if (p.center.dx > maxRight) maxRight = p.center.dx;
      if (p.center.dy > maxBottom) maxBottom = p.center.dy;
    }
    // The place stretches whichever way the words go (negatives included);
    // the box just hints painters, children may overflow it freely.
    final left = math.min(0.0, minX - _margin);
    final top = math.min(0.0, minY - _margin);
    final w = math.max(2200.0, maxRight + _margin - left);
    final h = math.max(1500.0, maxBottom + _margin - top);
    return (placed: placed, edges: edges, canvas: Size(w, h));
  }

  @override
  Widget build(BuildContext context) {
    final keys = widget.graph.sortedKeys();
    final sel = _selected != null ? widget.graph.get(_selected!) : null;
    final laid = _layoutAll();
    _lastPlaced = {for (final p in laid.placed) p.word: p.center};
    _lastSizes = {
      for (final p in laid.placed) p.word: Size(p.w, p.h)
    };
  _lastEdges = laid.edges;
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
                      IconButton(
                        tooltip: 'Add a picture node',
                        onPressed: _addPicture,
                        icon: const Icon(
                            Icons.image_outlined,
                            size: 18,
                            color: PaperTheme.inkSoft),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
                          crossAxisAlignment:
                              WrapCrossAlignment.center,
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
                        if (sel.hasImage)
                          TextButton.icon(
                            onPressed: _removePicture,
                            icon: const Icon(
                                Icons.hide_image_outlined,
                                size: 15,
                                color: PaperTheme.inkSoft),
                            label: const Text(
                              'Remove picture',
                              style: TextStyle(
                                  color: PaperTheme.inkSoft,
                                  fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _MeaningBlock(
                      meaning: sel.meaning,
                      onEdit: _editMeaning,
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
                            // Endless dot grid: fixed to the world, so the
                            // place feels infinite whichever way you pan.
                            Positioned.fill(
                              child: ValueListenableBuilder<Matrix4>(
                                valueListenable: _pan,
                                builder: (_, _, _) => CustomPaint(
                                  size: cons.biggest,
                                  painter:
                                      _InfiniteDotPainter(_pan.value),
                                ),
                              ),
                            ),
                            InteractiveViewer(
                              transformationController: _pan,
                              panEnabled: _draggingNode == null,
                              scaleEnabled: _draggingNode == null,
                              constrained: false,
                              boundaryMargin:
                                  const EdgeInsets.all(double.infinity),
                              minScale: 0.05,
                              maxScale: 2.5,
                              child: SizedBox(
                                key: _canvasKey,
                                width: laid.canvas.width,
                                height: laid.canvas.height,
                                child: Stack(
                                clipBehavior: Clip.none,
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
                                          final e = _nearestEdge(pt);
                                          if (e != null) {
                                            _jumpDialog(e.a, e.b);
                                            return;
                                          }
                                          _newWordAt(pt);
                                        },
                                        child: Container(
                                            color:
                                                Colors.transparent),
                                      ),
                                    ),
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
                                    // Chip on the selected link: delete it,
                                    // or turn a jump back into a line.
                                    if (_selEdge != null)
                                      for (final e in laid.edges)
                                        if ((e.a == _selEdge!.a &&
                                                e.b == _selEdge!.b) ||
                                            (e.a == _selEdge!.b &&
                                                e.b == _selEdge!.a))
                                          Positioned(
                                            left: (e.mid.dx - 95)
                                                .clamp(
                                                    8.0,
                                                    (laid.canvas.width -
                                                            198)
                                                        .clamp(
                                                            8.0, 1e6)),
                                            top: (e.mid.dy - 52)
                                                .clamp(8.0, 1e6),
                                            child: GestureDetector(
                                              onTap:
                                                  _deleteSelectedEdge,
                                              child: Container(
                                                width: 190,
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                            horizontal:
                                                                6,
                                                            vertical:
                                                                4),
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
                                                        e.jump == null
                                                            ? 'Delete this link?'
                                                            : 'Jump ${e.jump}',
                                                        style:
                                                            const TextStyle(
                                                          color: PaperTheme
                                                              .ink,
                                                          fontSize:
                                                              11,
                                                          fontWeight:
                                                              FontWeight
                                                                  .w600,
                                                        ),
                                                        overflow:
                                                            TextOverflow
                                                                .ellipsis,
                                                      ),
                                                    ),
                                                    if (e.jump != null)
                                                      InkWell(
                                                        onTap: () =>
                                                            _unsjump(
                                                                e.a,
                                                                e.b),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(
                                                                    8),
                                                        child:
                                                            const Padding(
                                                          padding: EdgeInsets
                                                              .symmetric(
                                                                  horizontal:
                                                                      6,
                                                                  vertical:
                                                                      4),
                                                          child: Text(
                                                            'line',
                                                            style:
                                                                TextStyle(
                                                              color: PaperTheme
                                                                  .inkSoft,
                                                              fontSize:
                                                                  11,
                                                              decoration:
                                                                  TextDecoration
                                                                      .underline,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    const Padding(
                                                      padding:
                                                          EdgeInsets.all(
                                                              4),
                                                      child: Icon(
                                                          Icons
                                                              .delete_outline,
                                                          size: 14,
                                                          color: PaperTheme
                                                              .ink),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                    for (final p in laid.placed)
                                      Positioned(
                                        left: p.center.dx - p.w / 2,
                                        top: p.center.dy - p.h / 2,
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
                                            picture:
                                                _nodePicture(p.word),
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
                                      tooltip: 'Fit everything in view',
                                      onPressed: _fitView,
                                      icon: const Icon(
                                          Icons.fit_screen,
                                          size: 16,
                                          color:
                                              PaperTheme.inkSoft),
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

/// Meaning line in the inspector: hidden on the canvas, shown here.
/// Tap to view the full text or to add one when missing.
class _MeaningBlock extends StatelessWidget {
  final String? meaning;
  final VoidCallback onEdit;
  const _MeaningBlock({required this.meaning, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final has = meaning != null && meaning!.trim().isNotEmpty;
    return InkWell(
      onTap: onEdit,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2, right: 6),
              child: Icon(Icons.menu_book_outlined,
                  size: 14, color: PaperTheme.inkSoft),
            ),
            Expanded(
              child: has
                  ? ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxHeight: 96),
                      child: SingleChildScrollView(
                        child: Text(
                          meaning!,
                          style: const TextStyle(
                            color: PaperTheme.ink,
                            fontSize: 12.5,
                            fontStyle: FontStyle.italic,
                            height: 1.4,
                          ),
                        ),
                      ),
                    )
                  : const Text(
                      'Add a meaning…',
                      style: TextStyle(
                        color: PaperTheme.inkSoft,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.edit_outlined,
                  size: 13, color: PaperTheme.inkSoft),
            ),
          ],
        ),
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

/// Soft rounded mind-map bubble (or picture card).
class _MapNode extends StatelessWidget {
  final String word;
  final Color fill;
  final bool isCenter;
  final bool linkSource;
  final Widget? picture;
  const _MapNode(
      {required this.word,
      required this.fill,
      required this.isCenter,
      this.linkSource = false,
      this.picture});

  @override
  Widget build(BuildContext context) {
    final pic = picture;
    if (pic != null) {
      return Container(
        width: GraphViewState._picW,
        height: GraphViewState._picH,
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(
              color: (isCenter || linkSource)
                  ? PaperTheme.inkSoft
                  : PaperTheme.lineThin,
              width: (isCenter || linkSource) ? 1.6 : 1),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3E3A31).withValues(alpha: 0.10),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(13)),
                child: SizedBox.expand(child: pic),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 5),
              child: Text(
                word,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: PaperTheme.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }
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
      if (e.jump != null) {
        _paintStub(canvas, e.from, e.to, e.jump!, selected);
        _paintStub(canvas, e.to, e.from, e.jump!, selected);
        continue;
      }
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

  void _paintStub(Canvas canvas, Offset anchor, Offset partner,
      String label, bool selected) {
    final s = _jumpStub(anchor, partner);
    canvas.drawLine(
        anchor,
        s.tip,
        Paint()
          ..color = selected ? PaperTheme.ink : PaperTheme.line
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 2.2 : 1.4
          ..strokeCap = StrokeCap.round);
    final rect = _jumpBadgeRect(s.tip, label);
    canvas.drawRRect(
        rect,
        Paint()
          ..color = selected
              ? PaperTheme.chip
              : const Color(0xFFF4EEDF));
    canvas.drawRRect(
        rect,
        Paint()
          ..color = selected ? PaperTheme.ink : PaperTheme.line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
    final tp = TextPainter(
      text: TextSpan(text: label, style: _jumpLabelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas,
        Offset(s.tip.dx - tp.width / 2, s.tip.dy - tp.height / 2));
    tp.dispose();
  }

  @override
  bool shouldRepaint(covariant _BranchPainter old) =>
      old.edges != edges ||
      old.tempFrom != tempFrom ||
      old.tempTo != tempTo ||
      old.selA != selA ||
      old.selB != selB;
}

/// Endless faint dot grid, pinned to world coordinates: wherever the
/// view pans or zooms, dots stay glued to the same world spots.
class _InfiniteDotPainter extends CustomPainter {
  final Matrix4 matrix;
  const _InfiniteDotPainter(this.matrix);

  @override
  void paint(Canvas canvas, Size size) {
    final s = matrix.getMaxScaleOnAxis();
    if (s <= 0 || !s.isFinite) return;
    // Far zoomed out, dots would be a 100k-circle mush: clean paper.
    if (s < 0.2) return;
    final tx = matrix.entry(0, 3);
    final ty = matrix.entry(1, 3);
    const step = 44.0;
    final paint = Paint()
      ..color = PaperTheme.lineThin.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;
    // World-space span currently on screen; dots snap to the grid.
    // (Clamped so a corrupt transform can never loop forever.)
    var wx = ((-tx / s).clamp(-1e6, 1e6) / step).floor() * step;
    final x1 = (size.width - tx) / s;
    final y1 = (size.height - ty) / s;
    for (; wx <= x1 && wx < 1e6; wx += step) {
      var wy = ((-ty / s).clamp(-1e6, 1e6) / step).floor() * step;
      for (; wy <= y1 && wy < 1e6; wy += step) {
        canvas.drawCircle(
            Offset(wx * s + tx, wy * s + ty), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_InfiniteDotPainter old) =>
      old.matrix != matrix;
}
