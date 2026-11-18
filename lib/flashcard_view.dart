import 'package:flutter/material.dart';

import 'flashcard_model.dart';
import 'graph_model.dart';
import 'repetition_logic.dart' show bundleFor;
import 'storage.dart';
import 'theme.dart';

/// The flash-card page: named bundles of a word and everything linked to
/// it, one card at a time, with the word in front and every sentence ever
/// written for it on the back.
class FlashCardView extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  final VoidCallback onGraphChanged;

  const FlashCardView({
    super.key,
    required this.storage,
    required this.graph,
    required this.onGraphChanged,
  });

  @override
  State<FlashCardView> createState() => FlashCardViewState();
}

class FlashCardViewState extends State<FlashCardView> {
  List<FlashBundle> _bundles = const [];
  List<FlashSentence> _sentences = const [];
  bool _loaded = false;

  FlashBundle? _active;
  int _index = 0;
  bool _flipped = false;
  bool _showAll = false;

  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _sentenceCtrl = TextEditingController();
  String? _pickWord;

  @override
  void initState() {
    super.initState();
    // The word list is filtered live as the user types in the picker.
    _searchCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    _reload();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _searchCtrl.dispose();
    _sentenceCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final bundles = await widget.storage.loadFlashBundles();
    final sentences = await widget.storage.loadFlashSentences();
    if (!mounted) return;
    setState(() {
      _bundles = bundles;
      _sentences = sentences;
      // A bundle may have been deleted or renamed in another place; keep
      // the open exercise by id rather than by a stale object reference.
      if (_active != null) {
        for (final b in _bundles) {
          if (b.id == _active!.id) {
            _active = b;
            break;
          }
        }
      }
      _loaded = true;
    });
  }

  // ---- Public hooks (Graph page + tests) ----

  /// Graph page: name a new bundle around [word], then open it.
  /// The name dialog lives here so both entry points behave the same.
  Future<void> requestNewBundle(String word) async {
    final key = WordGraph.norm(word);
    if (widget.graph.get(key) == null) return;
    _nameCtrl.text = '$key cards';
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PaperTheme.paper,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        title: Text('Name this bundle',
            style: const TextStyle(
                color: PaperTheme.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700)),
        content: TextField(
          controller: _nameCtrl,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
          style: const TextStyle(color: PaperTheme.ink, fontSize: 14),
          decoration: InputDecoration(
            hintText: '$key cards',
            hintStyle: const TextStyle(
                color: PaperTheme.inkSoft, fontSize: 13),
            filled: true,
            fillColor: PaperTheme.surface,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: PaperTheme.lineThin)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: PaperTheme.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_nameCtrl.text),
            child: const Text('Create',
                style: TextStyle(
                    color: PaperTheme.ink, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final name = picked.trim();
    await _createBundle(key, name.isEmpty ? '$key cards' : name);
  }

  @visibleForTesting
  List<FlashBundle> get debugBundles => _bundles;

  @visibleForTesting
  List<FlashSentence> get debugSentences => _sentences;

  @visibleForTesting
  String get debugCurrentWord => _currentWord;

  @visibleForTesting
  Future<void> debugCreateBundle(String word, String name) =>
      _createBundle(word, name);

  // ---- Bundle lifecycle ----

  Future<void> _createBundle(String rawWord, String name) async {
    final key = WordGraph.norm(rawWord);
    // The bundle is a snapshot: later map edits cannot reshuffle an
    // exercise already in progress. Links are undirected in WordGraph, so
    // bundleFor picks up inbound and outbound connections alike.
    final words = bundleFor(widget.graph, key);
    if (words.isEmpty) {
      _notice('That word is no longer on the map.');
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final bundle = FlashBundle(
      id: 'fb-$now-${_bundles.length}',
      name: name.trim().isEmpty ? '$key cards' : name.trim(),
      rootWord: key,
      words: List<String>.of(words),
      createdAt: now,
    );
    final next = [bundle, ..._bundles];
    await widget.storage.saveFlashBundles(next);
    if (!mounted) return;
    setState(() {
      _bundles = next;
      _active = bundle;
      _index = 0;
      _flipped = false;
      _showAll = false;
      _pickWord = null;
      _nameCtrl.clear();
      _searchCtrl.clear();
      _sentenceCtrl.clear();
    });
    _notice('"${bundle.name}" ready — ${words.length} cards.');
  }

  void _startNew() {
    setState(() {
      _active = null;
      _index = 0;
      _flipped = false;
      _showAll = false;
      _pickWord = null;
      _nameCtrl.clear();
      _searchCtrl.clear();
      _sentenceCtrl.clear();
    });
  }

  void _openBundle(FlashBundle bundle) {
    setState(() {
      _active = bundle;
      _index = 0;
      _flipped = false;
      _showAll = false;
      _sentenceCtrl.clear();
    });
  }

  Future<void> _deleteBundle(FlashBundle bundle) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PaperTheme.paper,
        title: const Text('Delete this bundle?',
            style: TextStyle(
                color: PaperTheme.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700)),
        content: Text(
          '"${bundle.name}" and the sentences written in it will be removed. '
          'Sentences for these words in other bundles stay.',
          style: const TextStyle(color: PaperTheme.inkSoft, fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: PaperTheme.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(color: Color(0xFF8F2F25))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final nextBundles =
        _bundles.where((b) => b.id != bundle.id).toList();
    final nextSentences =
        _sentences.where((s) => s.bundleId != bundle.id).toList();
    await widget.storage.saveFlashBundles(nextBundles);
    await widget.storage.saveFlashSentences(nextSentences);
    if (!mounted) return;
    setState(() {
      _bundles = nextBundles;
      _sentences = nextSentences;
      if (_active?.id == bundle.id) {
        _active = null;
        _index = 0;
        _flipped = false;
        _showAll = false;
      }
    });
    _notice('Bundle "${bundle.name}" deleted.');
  }

  // ---- Cards and sentences ----

  String get _currentWord {
    final b = _active;
    if (b == null || b.words.isEmpty) return '';
    return b.words[_index.clamp(0, b.words.length - 1)];
  }

  List<FlashSentence> _sentencesFor(String word) {
    final list =
        _sentences.where((s) => s.word == word).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  List<FlashSentence> _bundleSentences() {
    final b = _active;
    if (b == null) return const [];
    final order = <String, int>{
      for (var i = 0; i < b.words.length; i++) b.words[i]: i,
    };
    final list =
        _sentences.where((s) => s.bundleId == b.id).toList()
          ..sort((a, c) {
            final oa = order[a.word] ?? 1 << 30;
            final oc = order[c.word] ?? 1 << 30;
            if (oa != oc) return oa.compareTo(oc);
            return a.createdAt.compareTo(c.createdAt);
          });
    return list;
  }

  void _step(int delta) {
    final b = _active;
    if (b == null || b.words.isEmpty) return;
    setState(() {
      _index = (_index + delta + b.words.length) % b.words.length;
      _flipped = false;
      _sentenceCtrl.clear();
    });
  }

  Future<void> _addSentence() async {
    final b = _active;
    if (b == null) return;
    final text = _sentenceCtrl.text.trim();
    if (text.isEmpty) {
      _notice('Type a sentence first.');
      return;
    }
    final now = DateTime.now();
    final sentence = FlashSentence(
      id: 'fs-${now.microsecondsSinceEpoch}',
      bundleId: b.id,
      word: _currentWord,
      text: text,
      createdAt: now.millisecondsSinceEpoch,
    );
    final next = [..._sentences, sentence];
    await widget.storage.saveFlashSentences(next);
    b.updatedAt = sentence.createdAt;
    await widget.storage.saveFlashBundles(_bundles);
    if (!mounted) return;
    setState(() {
      _sentences = next;
      _sentenceCtrl.clear();
      _flipped = true; // show the newly written sentence on the back
    });
    _notice('Saved behind "${sentence.word}".');
  }

  Future<void> _deleteSentence(FlashSentence sentence) async {
    final next =
        _sentences.where((s) => s.id != sentence.id).toList();
    await widget.storage.saveFlashSentences(next);
    if (!mounted) return;
    setState(() => _sentences = next);
  }

  void _notice(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            style: const TextStyle(color: PaperTheme.ink, fontSize: 12)),
        backgroundColor: PaperTheme.card,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ---- Layout ----

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PaperTheme.paper,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildRail(),
          Expanded(
            child: !_loaded
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : (_active == null ? _buildStart() : _buildExercise()),
          ),
        ],
      ),
    );
  }

  Widget _buildRail() {
    return Container(
      width: 216,
      decoration: const BoxDecoration(
        color: PaperTheme.paperDark,
        border: Border(right: BorderSide(color: PaperTheme.lineThin)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 6, 4),
            child: Row(
              children: [
                const Text('BUNDLES',
                    style: TextStyle(
                        color: PaperTheme.inkSoft,
                        fontSize: 11,
                        letterSpacing: 1.2)),
                const Spacer(),
                IconButton(
                  tooltip: 'New bundle',
                  onPressed: _startNew,
                  icon: const Icon(Icons.add,
                      size: 18, color: PaperTheme.ink),
                ),
              ],
            ),
          ),
          Expanded(
            child: _bundles.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'No bundles yet. Pick a word on the Graph page, '
                      'or search for one here.',
                      style: TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 11),
                    ),
                  )
                : ListView.builder(
                    itemCount: _bundles.length,
                    itemBuilder: (context, i) =>
                        _bundleRow(_bundles[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _bundleRow(FlashBundle bundle) {
    final active = _active?.id == bundle.id;
    final count =
        _sentences.where((s) => s.bundleId == bundle.id).length;
    return InkWell(
      onTap: () => _openBundle(bundle),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        decoration: BoxDecoration(
          color: active ? PaperTheme.chip : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(bundle.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: PaperTheme.ink,
                          fontSize: 13,
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.normal)),
                  const SizedBox(height: 2),
                  Text(
                    '${bundle.rootWord} · ${bundle.words.length} cards · $count sentences',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: PaperTheme.inkSoft, fontSize: 10),
                  ),
                ],
              ),
            ),
            InkWell(
              onTap: () => _deleteBundle(bundle),
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.delete_outline,
                    size: 13, color: PaperTheme.inkSoft),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Picker shown when no bundle is open: name it, then choose a word.
  Widget _buildStart() {
    final query = _searchCtrl.text.trim().toLowerCase();
    final words = widget.graph.sortedKeys().where(
        (w) => query.isEmpty || w.contains(query)).toList();
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 22),
            decoration: BoxDecoration(
              color: const Color(0xFFEFE8D6),
              border: Border.all(color: PaperTheme.lineThin),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Flash cards',
                    style: TextStyle(
                        color: PaperTheme.ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                const Text(
                  'Pick a word — every word linked to it (either way) '
                  'becomes a card in one named bundle.',
                  style: TextStyle(
                      color: PaperTheme.inkSoft, fontSize: 11),
                ),
                const SizedBox(height: 14),
                _paperField(_nameCtrl, 'Bundle name', 'e.g. smooth cards'),
                const SizedBox(height: 8),
                _paperField(_searchCtrl, 'Find a graph word…',
                    'type to filter the map'),
                const SizedBox(height: 4),
                if (_pickWord != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle,
                            size: 13, color: Color(0xFF2E7D32)),
                        const SizedBox(width: 5),
                        Text('selected: $_pickWord',
                            style: const TextStyle(
                                color: PaperTheme.ink,
                                fontSize: 11,
                                fontWeight: FontWeight.w700)),
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              setState(() => _pickWord = null),
                          child: const Text('clear',
                              style: TextStyle(
                                  color: PaperTheme.inkSoft,
                                  fontSize: 11)),
                        ),
                      ],
                    ),
                  ),
                Container(
                  height: 240,
                  decoration: BoxDecoration(
                    color: PaperTheme.surface,
                    border: Border.all(color: PaperTheme.lineThin),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: words.isEmpty
                      ? const Center(
                          child: Text(
                            'No word on the map matches that.',
                            style: TextStyle(
                                color: PaperTheme.inkSoft, fontSize: 12),
                          ),
                        )
                      : ListView.builder(
                          itemCount: words.length,
                          itemBuilder: (context, i) {
                            final w = words[i];
                            final size = bundleFor(widget.graph, w).length;
                            final selected = _pickWord == w;
                            return InkWell(
                              onTap: () => setState(() {
                                _pickWord = w;
                                if (_nameCtrl.text.trim().isEmpty) {
                                  _nameCtrl.text = '$w cards';
                                }
                              }),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                color: selected
                                    ? PaperTheme.chip
                                    : Colors.transparent,
                                child: Row(
                                  children: [
                                    Icon(
                                      selected
                                          ? Icons.check_circle
                                          : Icons.circle_outlined,
                                      size: 14,
                                      color: PaperTheme.inkSoft,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(w,
                                          style: const TextStyle(
                                              color: PaperTheme.ink,
                                              fontSize: 14)),
                                    ),
                                    Text(
                                      '$size card${size == 1 ? '' : 's'}',
                                      style: const TextStyle(
                                          color: PaperTheme.inkSoft,
                                          fontSize: 10.5),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: PaperTheme.ink,
                      foregroundColor: PaperTheme.paper,
                    ),
                    onPressed: _pickWord == null
                        ? null
                        : () => _createBundle(
                            _pickWord!,
                            _nameCtrl.text.trim().isEmpty
                                ? '$_pickWord cards'
                                : _nameCtrl.text.trim()),
                    icon: const Icon(Icons.style_outlined, size: 16),
                    label: const Text('Create bundle'),
                  ),
                ),
                const SizedBox(height: 64), // floating nav pill clearance
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _paperField(
      TextEditingController controller, String label, String hint) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: PaperTheme.lineThin),
    );
    return TextField(
      controller: controller,
      style: const TextStyle(color: PaperTheme.ink, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
            color: PaperTheme.inkSoft, fontSize: 11),
        hintText: hint,
        hintStyle:
            const TextStyle(color: PaperTheme.inkSoft, fontSize: 12),
        filled: true,
        fillColor: PaperTheme.surface,
        isDense: true,
        border: border,
        enabledBorder: border,
        focusedBorder: border,
      ),
    );
  }

  /// One open exercise: header, card (or the bundle's sentence list), and
  /// the writing field under the card.
  Widget _buildExercise() {
    final b = _active!;
    final total = b.words.length;
    final allSentences = _bundleSentences();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(b.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: PaperTheme.ink,
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    Text(
                      '${b.rootWord} · $total cards · ${allSentences.length} sentences',
                      style: const TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 11),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _showAll = !_showAll),
                icon: Icon(
                    _showAll ? Icons.credit_card : Icons.list_alt,
                    size: 15),
                label: Text(_showAll ? 'Cards' : 'All sentences'),
                style: TextButton.styleFrom(
                    foregroundColor: PaperTheme.ink),
              ),
              TextButton(
                onPressed: _startNew,
                child: const Text('Back to bundles',
                    style: TextStyle(
                        color: PaperTheme.inkSoft, fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 880),
                child: _showAll
                    ? _buildAllSentences(allSentences)
                    : _buildCards(_currentWord, total),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCards(String word, int total) {
    final saved = _sentencesFor(word);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => setState(() => _flipped = !_flipped),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _flipped
                  ? _cardBack(word, saved)
                  : _cardFront(word, total, saved.length),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: const Color(0xFFEFE8D6),
              border: Border.all(color: PaperTheme.lineThin),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _sentenceCtrl,
                  minLines: 1,
                  maxLines: 3,
                  onSubmitted: (_) => _addSentence(),
                  style: const TextStyle(
                      color: PaperTheme.ink, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Write a sentence with "$word"…',
                    hintStyle: const TextStyle(
                        color: PaperTheme.inkSoft, fontSize: 12),
                    filled: true,
                    fillColor: PaperTheme.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                          color: PaperTheme.lineThin),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: PaperTheme.ink,
                      foregroundColor: PaperTheme.paper,
                    ),
                    onPressed: _addSentence,
                    icon: const Icon(Icons.add, size: 15),
                    label: const Text('Add sentence'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              OutlinedButton.icon(
                onPressed: () => _step(-1),
                icon: const Icon(Icons.arrow_back, size: 15),
                label: const Text('Previous'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: PaperTheme.ink),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    setState(() => _flipped = !_flipped),
                icon: const Icon(Icons.flip, size: 15),
                label: const Text('Flip'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: PaperTheme.ink),
              ),
              OutlinedButton.icon(
                onPressed: () => _step(1),
                icon: const Icon(Icons.arrow_forward, size: 15),
                label: const Text('Next'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: PaperTheme.ink),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Card ${_index + 1} of $total · tap the card to flip',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: PaperTheme.inkSoft, fontSize: 10.5),
          ),
          // Clearance for the floating nav pill at the bottom of the app.
          const SizedBox(height: 72),
        ],
      ),
    );
  }

  Widget _cardFront(String word, int total, int saved) {
    return Container(
      key: const ValueKey('front'),
      height: 210,
      decoration: BoxDecoration(
        color: const Color(0xFFEFE8D6),
        border: Border.all(color: PaperTheme.line),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF3E3A31).withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('FRONT · tap to flip',
              style: TextStyle(
                  color: PaperTheme.inkSoft,
                  fontSize: 10,
                  letterSpacing: 1)),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(word,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: PaperTheme.ink,
                    fontSize: 38,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 10),
          Text(
            saved == 0
                ? 'no sentences yet'
                : '$saved saved sentence${saved == 1 ? '' : 's'} — flip to read',
            style: const TextStyle(
                color: PaperTheme.inkSoft, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _cardBack(String word, List<FlashSentence> sentences) {
    return Container(
      key: const ValueKey('back'),
      height: 210,
      decoration: BoxDecoration(
        color: const Color(0xFFE5DCC5),
        border: Border.all(color: PaperTheme.line),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF3E3A31).withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Text('BACK · sentences for "$word"',
                style: const TextStyle(
                    color: PaperTheme.inkSoft,
                    fontSize: 10,
                    letterSpacing: 0.6)),
          ),
          Expanded(
            child: sentences.isEmpty
                ? const Center(
                    child: Text(
                      'Nothing here yet. Write one below.',
                      style: TextStyle(
                          color: PaperTheme.inkSoft,
                          fontSize: 12,
                          fontStyle: FontStyle.italic),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 2),
                    itemCount: sentences.length,
                    itemBuilder: (context, i) {
                      final s = sentences[i];
                      FlashBundle? from;
                      for (final b in _bundles) {
                        if (b.id == s.bundleId) {
                          from = b;
                          break;
                        }
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(s.text,
                                      style: const TextStyle(
                                          color: PaperTheme.ink,
                                          fontSize: 13)),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${from?.name ?? 'removed bundle'} · ${flashDateLabel(s.createdAt)}',
                                    style: const TextStyle(
                                        color: PaperTheme.inkSoft,
                                        fontSize: 9.5),
                                  ),
                                ],
                              ),
                            ),
                            InkWell(
                              onTap: () => _deleteSentence(s),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(Icons.delete_outline,
                                    size: 13,
                                    color: PaperTheme.inkSoft),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Everything written in this bundle, whatever the word.
  Widget _buildAllSentences(List<FlashSentence> sentences) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFEFE8D6),
        border: Border.all(color: PaperTheme.lineThin),
        borderRadius: BorderRadius.circular(10),
      ),
      child: sentences.isEmpty
          ? const Center(
              child: Text(
                'No sentences written in this bundle yet.',
                style: TextStyle(
                    color: PaperTheme.inkSoft,
                    fontSize: 12,
                    fontStyle: FontStyle.italic),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: sentences.length,
              itemBuilder: (context, i) {
                final s = sentences[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: PaperTheme.surface,
                    border: Border.all(color: PaperTheme.lineThin),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: PaperTheme.chip,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(s.word,
                            style: const TextStyle(
                                color: PaperTheme.ink,
                                fontSize: 11,
                                fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(s.text,
                                style: const TextStyle(
                                    color: PaperTheme.ink,
                                    fontSize: 13)),
                            const SizedBox(height: 3),
                            Text(flashDateLabel(s.createdAt),
                                style: const TextStyle(
                                    color: PaperTheme.inkSoft,
                                    fontSize: 10)),
                          ],
                        ),
                      ),
                      InkWell(
                        onTap: () => _deleteSentence(s),
                        child: const Icon(Icons.delete_outline,
                            size: 14, color: PaperTheme.inkSoft),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
