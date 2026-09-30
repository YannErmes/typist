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
  State<GraphView> createState() => _GraphViewState();
}

class _Placed {
  final String word;
  final Offset center;
  _Placed(this.word, this.center);
}

class _Edge {
  final Offset from; // bottom-center of parent bubble
  final Offset to; // top-center of child bubble
  _Edge(this.from, this.to);
}

class _GraphViewState extends State<GraphView> {
  String? _selected;
  final _childCtrl = TextEditingController();
  final _parentCtrl = TextEditingController();
  final _jumpCtrl = TextEditingController();
  final TransformationController _pan = TransformationController();

  /// User drag offsets per word, applied on top of the auto tree layout.
  Map<String, Offset> _drag = {};

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
    final init = widget.initialWord;
    if (init != null && widget.graph.get(init) != null) {
      _selected = WordGraph.norm(init);
    }
  }

  Future<void> _persist() async {
    await widget.storage.saveGraph(widget.graph);
    widget.onGraphChanged();
    setState(() {});
  }

  void _select(String word) {
    setState(() {
      _selected = WordGraph.norm(word);
      _childCtrl.clear();
      _parentCtrl.clear();
    });
    widget.onSelectionChanged?.call(_selected);
  }

  void _resetView() {
    setState(() {
      _drag = {};
      _pan.value = Matrix4.identity();
    });
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

    // Apply user drags.
    final placed = <_Placed>[];
    pos.forEach((w, p) {
      placed.add(_Placed(w, p + (_drag[w] ?? Offset.zero)));
    });
    final byWord = {for (final p in placed) p.word: p.center};

    // One bendy arrow per parent -> child link, pointing down at the child.
    final edges = <_Edge>[];
    for (final n in g.nodes.values) {
      final from = byWord[WordGraph.norm(n.name)];
      if (from == null) continue;
      for (final c in n.children) {
        final to = byWord[c];
        if (to == null) continue;
        edges.add(_Edge(
          Offset(from.dx, from.dy + _nodeH / 2),
          Offset(to.dx, to.dy - _nodeH / 2),
        ));
      }
    }

    final w = math.max(2200.0, _margin * 2 + slot * _slotGap);
    final h = math.max(1500.0, _margin * 2 + (maxDepth + 1) * _levelGap);
    return (placed: placed, edges: edges, canvas: Size(w, h));
  }

  @override
  Widget build(BuildContext context) {
    final keys = widget.graph.sortedKeys();
    final sel = _selected != null ? widget.graph.get(_selected!) : null;
    final laid = _layoutAll();

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
                      ? const Center(
                          child: Text(
                            'Create your first word on the left — the whole network grows here as trees.',
                            style: TextStyle(
                                color: PaperTheme.inkSoft,
                                fontSize: 14),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : Stack(
                          children: [
                            InteractiveViewer(
                              transformationController: _pan,
                              constrained: false,
                              boundaryMargin:
                                  const EdgeInsets.all(double.infinity),
                              minScale: 0.3,
                              maxScale: 2.5,
                              child: SizedBox(
                                width: laid.canvas.width,
                                height: laid.canvas.height,
                                child: Stack(
                                  children: [
                                    const Positioned.fill(
                                        child: _DotGrid()),
                                    CustomPaint(
                                      size: laid.canvas,
                                      painter:
                                          _BranchPainter(laid.edges),
                                    ),
                                    for (final p in laid.placed)
                                      Positioned(
                                        left: p.center.dx -
                                            _nodeW / 2,
                                        top: p.center.dy -
                                            _nodeH / 2,
                                        child: GestureDetector(
                                          onPanUpdate:
                                              (details) {
                                            final s = _pan.value
                                                .getMaxScaleOnAxis()
                                                .clamp(0.3, 2.5);
                                            setState(() {
                                              _drag[p.word] =
                                                  (_drag[p.word] ??
                                                      Offset
                                                          .zero) +
                                                      details.delta /
                                                          s;
                                            });
                                          },
                                          onTap: () =>
                                              _select(p.word),
                                          child: _MapNode(
                                            word: p.word,
                                            isCenter:
                                                p.word == _selected,
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
                                      tooltip: 'Tidy up + reset view',
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
                                'drag to wander · scroll to zoom · drag bubbles to arrange · click a bubble to edit',
                                style: TextStyle(
                                    color: PaperTheme.inkSoft,
                                    fontSize: 10),
                              ),
                            ),
                          ],
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
  final VoidCallback? onUnlink;
  const _MapNode(
      {required this.word, required this.isCenter, this.onUnlink});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _GraphViewState._nodeW,
      height: _GraphViewState._nodeH,
      decoration: BoxDecoration(
        color: isCenter
            ? PaperTheme.card
            : const Color(0xFFE4DCC7),
        border: Border.all(
            color: isCenter ? PaperTheme.inkSoft : PaperTheme.lineThin,
            width: isCenter ? 1.6 : 1),
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
  _BranchPainter(this.edges);

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
      final dy = (e.to.dy - e.from.dy).clamp(24.0, 600.0);
      final c1 = Offset(e.from.dx, e.from.dy + dy * 0.55);
      final c2 = Offset(e.to.dx, e.to.dy - dy * 0.55);
      final path = Path()
        ..moveTo(e.from.dx, e.from.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, e.to.dx, e.to.dy);
      canvas.drawPath(path, line);
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
  }

  @override
  bool shouldRepaint(covariant _BranchPainter old) => old.edges != edges;
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
