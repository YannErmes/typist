import 'dart:async';

import 'package:flutter/material.dart';

import 'graph_model.dart';
import 'graph_view.dart';
import 'repetition_logic.dart';
import 'storage.dart';
import 'theme.dart';

/// The practice stack: every repetition sorted by time left, most urgent
/// on top. Tapping a card opens its writing practice.
class RepetitionView extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  final VoidCallback onGraphChanged;

  const RepetitionView({
    super.key,
    required this.storage,
    required this.graph,
    required this.onGraphChanged,
  });

  @override
  State<RepetitionView> createState() => RepetitionViewState();
}

class RepetitionViewState extends State<RepetitionView> {
  List<RepetitionItem> _items = [];
  bool _loaded = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _reload();
    // Keep every countdown honest while the page sits open.
    _ticker = Timer.periodic(
        const Duration(seconds: 30), (_) => _reload());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await widget.storage.loadRepetition();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loaded = true;
    });
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

  Future<void> _openPractice(RepetitionItem item) async {
    final bundle = bundleFor(widget.graph, item.word);
    if (bundle.isEmpty) {
      _notice('"${item.word}" left the map — delete its practice.');
      return;
    }
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RepetitionPracticeView(
          storage: widget.storage,
          graph: widget.graph,
          onGraphChanged: widget.onGraphChanged,
          item: item,
        ),
      ),
    );
    await _reload();
    if (done == true && mounted) {
      _notice(
          'Next review ${intervalText(item.intervalMinutes)}.');
    }
  }

  Future<void> _delete(RepetitionItem item) async {
    final items = await widget.storage.loadRepetition();
    items.removeWhere((e) => e.id == item.id);
    await widget.storage.saveRepetition(items);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final sorted = List<RepetitionItem>.of(_items)
      ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
    return Container(
      color: PaperTheme.paper,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Container(
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
            decoration: BoxDecoration(
              color: const Color(0xFFEFE8D6),
              border:
                  Border.all(color: PaperTheme.lineThin, width: 1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: !_loaded
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2),
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Spaced repetition',
                        style: TextStyle(
                          color: PaperTheme.ink,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'most urgent on top — write with every word in the bundle',
                        style: TextStyle(
                            color: PaperTheme.inkSoft,
                            fontSize: 11),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: sorted.isEmpty
                            ? const Center(
                                child: Text(
                                  'No practices yet.\nSelect a word on the Graph page and tap the repeat button.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: PaperTheme.inkSoft,
                                      fontSize: 13),
                                ),
                              )
                            : ListView.builder(
                                itemCount: sorted.length,
                                itemBuilder: (context, i) =>
                                    _PracticeCard(
                                  item: sorted[i],
                                  now: now,
                                  bundleSize: bundleFor(widget.graph,
                                          sorted[i].word)
                                      .length,
                                  onOpen: () =>
                                      _openPractice(sorted[i]),
                                  onDelete: () =>
                                      _delete(sorted[i]),
                                ),
                              ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _PracticeCard extends StatelessWidget {
  final RepetitionItem item;
  final int now;
  final int bundleSize;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  const _PracticeCard({
    required this.item,
    required this.now,
    required this.bundleSize,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final overdue = item.dueAt <= now;
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: overdue
              ? const Color(0xFFF2CFC8)
              : PaperTheme.surface,
          border: Border.all(
              color: overdue
                  ? const Color(0xFFB3261E)
                  : PaperTheme.lineThin),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(item.word,
                      style: const TextStyle(
                          color: PaperTheme.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    '$bundleSize word${bundleSize == 1 ? '' : 's'} in bundle · ${intervalText(item.intervalMinutes)}',
                    style: const TextStyle(
                        color: PaperTheme.inkSoft,
                        fontSize: 11),
                  ),
                ],
              ),
            ),
            Text(dueText(item.dueAt, now),
                style: TextStyle(
                    color: overdue
                        ? const Color(0xFFB3261E)
                        : PaperTheme.inkSoft,
                    fontSize: 12,
                    fontWeight: overdue
                        ? FontWeight.w700
                        : FontWeight.normal)),
            IconButton(
              tooltip: 'Delete this practice',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline,
                  size: 17, color: PaperTheme.inkSoft),
            ),
          ],
        ),
      ),
    );
  }
}

/// One writing practice: every bundle word on screen, a writing area,
/// and a live count of used words. Tapping a word peeks at the graph
/// (full picture) without losing a syllable.
class RepetitionPracticeView extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  final VoidCallback onGraphChanged;
  final RepetitionItem item;

  const RepetitionPracticeView({
    super.key,
    required this.storage,
    required this.graph,
    required this.onGraphChanged,
    required this.item,
  });

  @override
  State<RepetitionPracticeView> createState() =>
      RepetitionPracticeViewState();
}

class RepetitionPracticeViewState
    extends State<RepetitionPracticeView> {
  final TextEditingController _text = TextEditingController();
  late List<String> _bundle;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bundle = bundleFor(widget.graph, widget.item.word);
    _text.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Set<String> get _used => usedWords(_text.text, _bundle);

  Future<void> _peekGraph(String word) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        backgroundColor: PaperTheme.paper,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: 720,
          height: 540,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(14, 8, 6, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Map around "$word"',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: PaperTheme.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w700)),
                    ),
                    InkWell(
                      onTap: () => Navigator.of(ctx).pop(),
                      borderRadius: BorderRadius.circular(12),
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(Icons.close,
                            size: 16,
                            color: PaperTheme.inkSoft),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GraphView(
                  storage: widget.storage,
                  graph: widget.graph,
                  onGraphChanged: widget.onGraphChanged,
                  initialWord: word,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // The peek may have edited the map: refresh the bundle, keep typing.
    if (mounted) {
      setState(() {
        _bundle = bundleFor(widget.graph, widget.item.word);
      });
    }
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final items = await widget.storage.loadRepetition();
      for (final e in items) {
        if (e.id == widget.item.id) {
          e.dueAt = now + e.intervalMinutes * 60000;
          break;
        }
      }
      await widget.storage.saveRepetition(items);
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final used = _used;
    return Scaffold(
      backgroundColor: PaperTheme.paper,
      appBar: AppBar(
        backgroundColor: PaperTheme.paperDark,
        foregroundColor: PaperTheme.ink,
        elevation: 0,
        title: Text('Practice: ${widget.item.word}',
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Container(
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
            decoration: BoxDecoration(
              color: const Color(0xFFEFE8D6),
              border:
                  Border.all(color: PaperTheme.lineThin, width: 1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final w in _bundle)
                      InkWell(
                        onTap: () => _peekGraph(w),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: used.contains(w)
                                ? const Color(0xFFD9E8CF)
                                : PaperTheme.surface,
                            border: Border.all(
                                color: PaperTheme.lineThin),
                            borderRadius:
                                BorderRadius.circular(14),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (used.contains(w))
                                const Padding(
                                  padding:
                                      EdgeInsets.only(right: 4),
                                  child: Icon(Icons.check,
                                      size: 13,
                                      color: PaperTheme.ink),
                                ),
                              Text(w,
                                  style: const TextStyle(
                                      color: PaperTheme.ink,
                                      fontSize: 13,
                                      fontWeight:
                                          FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'tap a word to see it on the map — your text stays',
                  style: TextStyle(
                      color: PaperTheme.inkSoft, fontSize: 10.5),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: PaperTheme.surface,
                      border: Border.all(
                          color: PaperTheme.lineThin),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: TextField(
                      controller: _text,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                          color: PaperTheme.ink, fontSize: 14),
                      cursorColor: PaperTheme.ink,
                      decoration: const InputDecoration(
                        hintText:
                            'Write something using every word above…',
                        hintStyle: TextStyle(
                            color: PaperTheme.inkSoft),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${used.length} of ${_bundle.length} words used',
                        style: const TextStyle(
                            color: PaperTheme.inkSoft,
                            fontSize: 11.5),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _finish,
                      child: Text(_busy ? 'saving…' : 'Done practicing',
                          style: const TextStyle(
                              color: PaperTheme.ink,
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
