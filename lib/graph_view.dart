import 'package:flutter/material.dart';

import 'graph_model.dart';
import 'storage.dart';
import 'theme.dart';

/// Graph / settings view: center word, parents above, children below,
/// thin muted connecting lines, add child / parent.
class GraphView extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  final VoidCallback onGraphChanged;

  const GraphView({
    super.key,
    required this.storage,
    required this.graph,
    required this.onGraphChanged,
  });

  @override
  State<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<GraphView> {
  String? _selected;
  final _childCtrl = TextEditingController();
  final _parentCtrl = TextEditingController();
  final _jumpCtrl = TextEditingController();

  @override
  void dispose() {
    _childCtrl.dispose();
    _parentCtrl.dispose();
    _jumpCtrl.dispose();
    super.dispose();
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
    await _persist();
  }

  Future<void> _unlink(String parent, String child) async {
    widget.graph.unlinkParentChild(parent, child);
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final keys = widget.graph.sortedKeys();
    final sel = _selected != null ? widget.graph.get(_selected!) : null;
    final parents = sel == null
        ? <String>[]
        : (sel.parents.toList()..sort());
    final children = sel == null
        ? <String>[]
        : (sel.children.toList()..sort());

    return Container(
      color: PaperTheme.paper,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left: word list + jump box.
          Container(
            width: 230,
            decoration: const BoxDecoration(
              color: PaperTheme.paperDark,
              border: Border(
                  right: BorderSide(color: PaperTheme.lineThin)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _jumpCtrl,
                          onSubmitted: (_) => _createOrJump(),
                          style: const TextStyle(
                              color: PaperTheme.ink, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'new / find word…',
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
                                  BorderRadius.circular(6),
                              borderSide: const BorderSide(
                                  color: PaperTheme.lineThin),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(6),
                              borderSide: const BorderSide(
                                  color: PaperTheme.lineThin),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Create / jump',
                        onPressed: _createOrJump,
                        icon: const Icon(Icons.add,
                            color: PaperTheme.inkSoft),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'WORDS',
                    style: TextStyle(
                        color: PaperTheme.inkSoft,
                        fontSize: 11,
                        letterSpacing: 1.2),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: keys.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'No words yet.\nCreate one above, e.g. eat, then add orange and tomato under it.',
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
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8),
                                color: active
                                    ? PaperTheme.chip
                                    : Colors.transparent,
                                child: Text(
                                  k,
                                  style: TextStyle(
                                    color: PaperTheme.ink,
                                    fontSize: 13,
                                    fontWeight: active
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    widget.storage.basePath.isEmpty
                        ? ''
                        : 'Saved in\n${widget.storage.basePath}',
                    style: const TextStyle(
                        color: PaperTheme.inkSoft, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
          // Right: center graph.
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                  horizontal: 32, vertical: 28),
              child: sel == null
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.only(top: 80),
                        child: Text(
                          'Select a word on the left to see its parents above and children below.',
                          style: TextStyle(
                              color: PaperTheme.inkSoft,
                              fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.center,
                      children: [
                        const _RelLabel('parents above'),
                        const SizedBox(height: 8),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final p in parents)
                              _WordChip(
                                word: p,
                                onTap: () => _select(p),
                                onRemove: () =>
                                    _unlink(p, sel.name),
                              ),
                            if (parents.isEmpty)
                              const Text('— none —',
                                  style: TextStyle(
                                      color:
                                          PaperTheme.inkSoft,
                                      fontSize: 12)),
                          ],
                        ),
                        // Thin vertical connector.
                        Container(
                            width: 1,
                            height: 34,
                            color: PaperTheme.line),
                        // Center word.
                        Container(
                          padding:
                              const EdgeInsets.symmetric(
                                  horizontal: 28,
                                  vertical: 16),
                          decoration: BoxDecoration(
                            color: PaperTheme.card,
                            border: Border.all(
                                color: PaperTheme.line),
                            borderRadius:
                                BorderRadius.circular(8),
                          ),
                          child: Text(
                            sel.name,
                            style: const TextStyle(
                              color: PaperTheme.ink,
                              fontSize: 26,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Container(
                            width: 1,
                            height: 34,
                            color: PaperTheme.line),
                        const _RelLabel('children below'),
                        const SizedBox(height: 8),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final c in children)
                              _WordChip(
                                word: c,
                                onTap: () => _select(c),
                                onRemove: () =>
                                    _unlink(sel.name, c),
                              ),
                            if (children.isEmpty)
                              const Text('— none —',
                                  style: TextStyle(
                                      color:
                                          PaperTheme.inkSoft,
                                      fontSize: 12)),
                          ],
                        ),
                        const SizedBox(height: 28),
                        _AddRow(
                          label: 'Add child under "${sel.name}"',
                          controller: _childCtrl,
                          onAdd: _addChild,
                        ),
                        const SizedBox(height: 12),
                        _AddRow(
                          label: 'Add parent above "${sel.name}"',
                          controller: _parentCtrl,
                          onAdd: _addParent,
                        ),
                        const SizedBox(height: 20),
                        TextButton.icon(
                          onPressed: _deleteSelected,
                          icon: const Icon(Icons.delete_outline,
                              size: 16,
                              color: PaperTheme.inkSoft),
                          label: const Text(
                            'Delete this word',
                            style: TextStyle(
                                color: PaperTheme.inkSoft),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RelLabel extends StatelessWidget {
  final String text;
  const _RelLabel(this.text);
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
          color: PaperTheme.inkSoft,
          fontSize: 11,
          letterSpacing: 1.4),
    );
  }
}

class _WordChip extends StatelessWidget {
  final String word;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  const _WordChip(
      {required this.word, required this.onTap, required this.onRemove});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding:
            const EdgeInsets.only(left: 14, right: 6, top: 7, bottom: 7),
        decoration: BoxDecoration(
          color: PaperTheme.chip,
          border: Border.all(color: PaperTheme.lineThin),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(word,
                style: const TextStyle(
                    color: PaperTheme.ink, fontSize: 13)),
            InkWell(
              onTap: onRemove,
              child: const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.close,
                    size: 14, color: PaperTheme.inkSoft),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddRow extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final VoidCallback onAdd;
  const _AddRow(
      {required this.label, required this.controller, required this.onAdd});
  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onSubmitted: (_) => onAdd(),
              style:
                  const TextStyle(color: PaperTheme.ink, fontSize: 13),
              decoration: InputDecoration(
                hintText: label,
                hintStyle: const TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 12),
                filled: true,
                fillColor: PaperTheme.surface,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide:
                      const BorderSide(color: PaperTheme.lineThin),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide:
                      const BorderSide(color: PaperTheme.lineThin),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: onAdd,
            style: ElevatedButton.styleFrom(
              backgroundColor: PaperTheme.inkSoft,
              foregroundColor: PaperTheme.paper,
              elevation: 0,
            ),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
