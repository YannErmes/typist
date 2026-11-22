import 'package:flutter/material.dart';

import 'flashcard_model.dart';
import 'graph_model.dart';
import 'storage.dart';
import 'theme.dart';

enum _Page { deck, editor, review }
enum _Stage { answering, checking, revealed }

/// The flash-card page: a deck of single-target forced-retrieval cards.
/// The user sees a scenario and question, answers from habit, blocks each
/// default answer, and only gets the target after enough blocked attempts.
class FlashCardView extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  final VoidCallback onGraphChanged;

  /// Asks the shell to open the real Graph page to pick a target word.
  final VoidCallback onRequestPick;

  const FlashCardView({
    super.key,
    required this.storage,
    required this.graph,
    required this.onGraphChanged,
    required this.onRequestPick,
  });

  @override
  State<FlashCardView> createState() => FlashCardViewState();
}

class FlashCardViewState extends State<FlashCardView> {
  List<FlashCard> _cards = const [];
  bool _loaded = false;

  _Page _page = _Page.deck;
  _Stage _stage = _Stage.answering;
  FlashCard? _active;
  FlashCard? _editing;

  /// Reset every time a card is started; the blocked list is NOT reset.
  int _attempts = 0;

  final TextEditingController _targetCtrl = TextEditingController();
  final TextEditingController _scenarioCtrl = TextEditingController();
  final TextEditingController _questionCtrl = TextEditingController();
  final TextEditingController _answerCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _targetCtrl.dispose();
    _scenarioCtrl.dispose();
    _questionCtrl.dispose();
    _answerCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final cards = await widget.storage.loadFlashCards();
    if (!mounted) return;
    setState(() {
      _cards = cards;
      if (_active != null) {
        for (final c in _cards) {
          if (c.id == _active!.id) {
            _active = c;
            break;
          }
        }
      }
      _loaded = true;
    });
  }

  // ---- Public hooks (shell + tests) ----

  @visibleForTesting
  List<FlashCard> get debugCards => _cards;

  @visibleForTesting
  FlashCard? get debugActive => _active;

  @visibleForTesting
  String get debugTargetText => _targetCtrl.text;

  @visibleForTesting
  int get debugAttempts => _attempts;

  @visibleForTesting
  String get debugStage => _stage.name;

  @visibleForTesting
  Future<void> debugAddCard(FlashCard card) async {
    final next = [..._cards, card];
    await widget.storage.saveFlashCards(next);
    if (!mounted) return;
    setState(() => _cards = next);
  }

  /// Graph inspector: start a brand-new card with [word] as its target.
  void beginNewCardWithTarget(String word) {
    _startEditor(null);
    _targetCtrl.text = WordGraph.norm(word);
  }

  /// Graph pick mode: drop the chosen word into the target field.
  void applyPickedTarget(String word) {
    if (_page != _Page.editor) _startEditor(null);
    _targetCtrl.text = WordGraph.norm(word);
    if (mounted) setState(() {});
    _notice('Target set to "$word".');
  }

  // ---- Deck lifecycle ----

  void _startEditor(FlashCard? card) {
    _editing = card;
    _targetCtrl.text = card?.target ?? '';
    _scenarioCtrl.text = card?.scenario ?? '';
    _questionCtrl.text = card?.question ?? '';
    _stage = _Stage.answering;
    _attempts = 0;
    _answerCtrl.clear();
    if (mounted) setState(() => _page = _Page.editor);
  }

  void _startNew() => _startEditor(null);

  void _backToDeck() {
    if (mounted) {
      setState(() {
        _page = _Page.deck;
        _active = null;
        _editing = null;
        _answerCtrl.clear();
        _attempts = 0;
      });
    }
  }

  Future<void> _saveCard() async {
    final target = _targetCtrl.text.trim();
    if (target.isEmpty) {
      _notice('Type a target or pick one from the graph.');
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final card = _editing ??
        FlashCard(id: 'fc-$now-${_cards.length}', target: target);
    card.target = target;
    card.scenario = _scenarioCtrl.text.trim();
    card.question = _questionCtrl.text.trim();

    final next = List<FlashCard>.of(_cards);
    final at = next.indexWhere((c) => c.id == card.id);
    if (at >= 0) {
      next[at] = card;
    } else {
      next.add(card);
    }
    await widget.storage.saveFlashCards(next);
    if (!mounted) return;
    setState(() {
      _cards = next;
      _page = _Page.deck;
      _editing = null;
    });
    _notice('Card saved: $target');
  }

  Future<void> _deleteCard(FlashCard card) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PaperTheme.paper,
        title: const Text('Delete this card?',
            style: TextStyle(
                color: PaperTheme.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700)),
        content: Text('"${card.target}" and its blocked answers will be '
            'removed.',
            style:
                const TextStyle(color: PaperTheme.inkSoft, fontSize: 12)),
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
    final next = _cards.where((c) => c.id != card.id).toList();
    await widget.storage.saveFlashCards(next);
    if (!mounted) return;
    setState(() {
      _cards = next;
      if (_active?.id == card.id) _active = null;
      if (_editing?.id == card.id) _editing = null;
      if (_active == null && _editing == null) _page = _Page.deck;
    });
  }

  // ---- Review flow ----

  void _openReview(FlashCard card) {
    setState(() {
      _active = card;
      _page = _Page.review;
      _stage = _Stage.answering;
      _attempts = 0; // new session on this card; blocked list untouched
      _answerCtrl.clear();
    });
  }

  void _check() {
    if (_answerCtrl.text.trim().isEmpty) {
      _notice('Write an answer first.');
      return;
    }
    setState(() => _stage = _Stage.checking);
  }

  Future<void> _block() async {
    final card = _active;
    if (card == null) return;
    final answer = _answerCtrl.text.trim();
    if (answer.isEmpty) return;
    if (!card.blocked.contains(answer)) {
      card.blocked.add(answer);
      await widget.storage.saveFlashCards(_cards);
    }
    if (!mounted) return;
    final attempts = _attempts + 1;
    setState(() {
      _attempts = attempts;
      _answerCtrl.clear();
      // The target stays hidden until the attempt limit, then reveal it.
      _stage = attempts >= kRevealAfterBlocks
          ? _Stage.revealed
          : _Stage.answering;
    });
    if (attempts >= kRevealAfterBlocks) {
      _notice('Target revealed — try again using it.');
    } else if (!card.blocked.contains(answer)) {
      _notice('Default blocked.');
    } else {
      _notice('Already blocked — try another answer.');
    }
  }

  Future<void> _removeBlocked(String answer) async {
    final card = _active;
    if (card == null) return;
    card.blocked.remove(answer);
    await widget.storage.saveFlashCards(_cards);
    if (mounted) setState(() {});
  }

  Future<void> _good() async {
    final card = _active;
    if (card == null) return;
    final now = DateTime.now();
    card.goodCount += 1;
    card.lastGoodAt = now.millisecondsSinceEpoch;
    card.nextReview =
        now.add(const Duration(days: 1)).millisecondsSinceEpoch;
    await widget.storage.saveFlashCards(_cards);
    if (!mounted) return;

    final at = _cards.indexWhere((c) => c.id == card.id);
    _answerCtrl.clear();
    _attempts = 0;
    if (at >= 0 && at + 1 < _cards.length) {
      setState(() {
        _active = _cards[at + 1];
        _stage = _Stage.answering;
      });
      _notice('Good — next card.');
    } else {
      setState(() {
        _page = _Page.deck;
        _active = null;
        _stage = _Stage.answering;
      });
      _notice('Deck complete. Nice work.');
    }
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
                : switch (_page) {
                    _Page.deck => _buildDeck(),
                    _Page.editor => _buildEditor(),
                    _Page.review => _buildReview(),
                  },
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
                const Text('CARDS',
                    style: TextStyle(
                        color: PaperTheme.inkSoft,
                        fontSize: 11,
                        letterSpacing: 1.2)),
                const Spacer(),
                IconButton(
                  tooltip: 'New card',
                  onPressed: _startNew,
                  icon: const Icon(Icons.add,
                      size: 18, color: PaperTheme.ink),
                ),
              ],
            ),
          ),
          Expanded(
            child: _cards.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'No cards yet. Add one here, or pick a word on the '
                      'Graph page.',
                      style:
                          TextStyle(color: PaperTheme.inkSoft, fontSize: 11),
                    ),
                  )
                : ListView.builder(
                    itemCount: _cards.length,
                    itemBuilder: (context, i) => _cardRow(_cards[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _cardRow(FlashCard card) {
    final active = _active?.id == card.id || _editing?.id == card.id;
    return InkWell(
      onTap: () => _openReview(card),
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
                  Text(card.target,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: PaperTheme.ink,
                          fontSize: 13,
                          fontWeight:
                              active ? FontWeight.w700 : FontWeight.normal)),
                  const SizedBox(height: 2),
                  Text(
                    '${card.blocked.length} blocked · ${card.goodCount} good',
                    style: const TextStyle(
                        color: PaperTheme.inkSoft, fontSize: 10),
                  ),
                ],
              ),
            ),
            InkWell(
              onTap: () => _startEditor(card),
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.edit_outlined,
                    size: 13, color: PaperTheme.inkSoft),
              ),
            ),
            InkWell(
              onTap: () => _deleteCard(card),
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

  Widget _paperCard({required Widget child}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 22),
            decoration: BoxDecoration(
              color: const Color(0xFFEFE8D6),
              border: Border.all(color: PaperTheme.lineThin),
              borderRadius: BorderRadius.circular(10),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller, {
    required String label,
    required String hint,
    int maxLines = 1,
  }) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: PaperTheme.lineThin),
    );
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(color: PaperTheme.ink, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:
            const TextStyle(color: PaperTheme.inkSoft, fontSize: 11),
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

  Widget _buildDeck() {
    return _paperCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Flash cards',
              style: TextStyle(
                  color: PaperTheme.ink,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          const Text(
            'One target per card. Answer the question, block your default '
            'answers, and the target is revealed after '
            '$kRevealAfterBlocks attempts.',
            style: TextStyle(color: PaperTheme.inkSoft, fontSize: 11),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: PaperTheme.ink,
                foregroundColor: PaperTheme.paper,
              ),
              onPressed: _startNew,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add new card'),
            ),
          ),
          const SizedBox(height: 12),
          if (_cards.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Text(
                'No cards yet. Add one, or pick a word from the Graph page.',
                textAlign: TextAlign.center,
                style: TextStyle(color: PaperTheme.inkSoft, fontSize: 13),
              ),
            )
          else
            Column(
              children: [
                for (final card in _cards)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () => _openReview(card),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: PaperTheme.surface,
                          border: Border.all(color: PaperTheme.lineThin),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(card.target,
                                      style: const TextStyle(
                                          color: PaperTheme.ink,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 3),
                                  Text(
                                    card.scenario.isEmpty
                                        ? 'no scenario yet'
                                        : card.scenario,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: PaperTheme.inkSoft,
                                        fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${card.blocked.length} blocked · ${card.goodCount} good',
                              style: const TextStyle(
                                  color: PaperTheme.inkSoft, fontSize: 10.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 64), // floating nav pill clearance
        ],
      ),
    );
  }

  Widget _buildEditor() {
    return _paperCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TextButton.icon(
                onPressed: _backToDeck,
                icon: const Icon(Icons.arrow_back, size: 15),
                label: const Text('All cards'),
                style: TextButton.styleFrom(
                    foregroundColor: PaperTheme.inkSoft),
              ),
              const Spacer(),
              Text(
                _editing == null ? 'New card' : 'Edit card',
                style: const TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _field(_targetCtrl,
              label: 'Target word or expression',
              hint: 'e.g. garbage disposal'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                foregroundColor: PaperTheme.ink),
            onPressed: widget.onRequestPick,
            icon: const Icon(Icons.account_tree_outlined, size: 15),
            label: const Text('Pick from graph'),
          ),
          const SizedBox(height: 16),
          _field(_scenarioCtrl,
              label: 'Scenario',
              hint: 'Describe a situation…',
              maxLines: 3),
          const SizedBox(height: 10),
          _field(_questionCtrl,
              label: 'Question',
              hint: 'What would you ask in that situation?',
              maxLines: 2),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: PaperTheme.ink,
                    foregroundColor: PaperTheme.paper,
                  ),
                  onPressed: _saveCard,
                  icon: const Icon(Icons.save_outlined, size: 15),
                  label: const Text('Save card'),
                ),
              ),
              if (_editing != null) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _deleteCard(_editing!),
                  child: const Text('Delete',
                      style: TextStyle(color: Color(0xFF8F2F25))),
                ),
              ],
            ],
          ),
          const SizedBox(height: 64),
        ],
      ),
    );
  }

  Widget _infoBox(String label, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PaperTheme.surface,
        border: Border.all(color: PaperTheme.lineThin),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: PaperTheme.inkSoft,
                  fontSize: 10,
                  letterSpacing: 1.2)),
          const SizedBox(height: 6),
          Text(
            text.isEmpty ? '—' : text,
            style: const TextStyle(
                color: PaperTheme.ink,
                fontSize: 15,
                height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _blockedList(FlashCard card) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFE5DCC5),
        border: Border.all(color: PaperTheme.lineThin),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.block, size: 14, color: PaperTheme.inkSoft),
              const SizedBox(width: 6),
              Text(
                '${card.blocked.length} defaults eliminated',
                style: const TextStyle(
                    color: PaperTheme.ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (card.blocked.isEmpty)
            const Text('No defaults blocked for this card yet.',
                style: TextStyle(
                    color: PaperTheme.inkSoft,
                    fontSize: 11,
                    fontStyle: FontStyle.italic))
          else
            Column(
              children: [
                for (final answer in card.blocked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.remove_circle_outline,
                            size: 13, color: PaperTheme.inkSoft),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(answer,
                              style: const TextStyle(
                                  color: PaperTheme.ink, fontSize: 12)),
                        ),
                        InkWell(
                          onTap: () => _removeBlocked(answer),
                          child: const Padding(
                            padding: EdgeInsets.all(3),
                            child: Icon(Icons.close,
                                size: 13, color: PaperTheme.inkSoft),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildReview() {
    final card = _active!;
    final index = _cards.indexWhere((c) => c.id == card.id);
    return _paperCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Card ${index + 1} of ${_cards.length} · $_attempts/$kRevealAfterBlocks attempts',
                      style: const TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 11),
                    ),
                    Text(
                      '${card.goodCount} good · ${card.blocked.length} defaults eliminated',
                      style: const TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _startNew,
                icon: const Icon(Icons.add, size: 15),
                label: const Text('Add new card'),
                style: TextButton.styleFrom(
                    foregroundColor: PaperTheme.ink),
              ),
              TextButton(
                onPressed: _backToDeck,
                child: const Text('All cards',
                    style: TextStyle(
                        color: PaperTheme.inkSoft, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _infoBox('SCENARIO', card.scenario),
          const SizedBox(height: 10),
          _infoBox('QUESTION', card.question),
          const SizedBox(height: 12),

          if (_stage == _Stage.revealed)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFD9CFB0),
                border: Border.all(color: PaperTheme.inkSoft),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  const Text('TARGET REVEALED',
                      style: TextStyle(
                          color: PaperTheme.inkSoft,
                          fontSize: 10,
                          letterSpacing: 1.2)),
                  const SizedBox(height: 6),
                  Text(card.target,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: PaperTheme.ink,
                          fontSize: 26,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),

          if (_stage == _Stage.checking) ...[
            _infoBox('YOUR ANSWER', _answerCtrl.text.trim()),
            const SizedBox(height: 10),
          ] else ...[
            TextField(
              controller: _answerCtrl,
              maxLines: 2,
              onSubmitted: (_) => _stage == _Stage.revealed ? _good() : _check(),
              style: const TextStyle(color: PaperTheme.ink, fontSize: 13),
              decoration: InputDecoration(
                hintText: _stage == _Stage.revealed
                    ? 'Use "${card.target}" in your answer…'
                    : 'Answer in your own words…',
                hintStyle: const TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 12),
                filled: true,
                fillColor: PaperTheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      const BorderSide(color: PaperTheme.lineThin),
                ),
              ),
            ),
          ],

          // The blocked list stays visible from the first Check onward so
          // the user can keep comparing answers as defaults are eliminated.
          if (_stage != _Stage.answering || _attempts > 0) ...[
            const SizedBox(height: 10),
            _blockedList(card),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              if (_stage == _Stage.answering)
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: PaperTheme.ink,
                      foregroundColor: PaperTheme.paper,
                    ),
                    onPressed: _check,
                    icon: const Icon(Icons.search, size: 15),
                    label: const Text('Check'),
                  ),
                )
              else ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _block,
                    icon: const Icon(Icons.block, size: 15),
                    label: const Text('Block'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: PaperTheme.ink),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: PaperTheme.ink,
                      foregroundColor: PaperTheme.paper,
                    ),
                    onPressed: _good,
                    icon: const Icon(Icons.check, size: 15),
                    label: const Text('Good'),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 64), // floating nav pill clearance
        ],
      ),
    );
  }
}
