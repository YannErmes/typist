import 'package:flutter/material.dart';

import 'graph_model.dart';
import 'storage.dart';
import 'tag_sheet.dart';
import 'theme.dart';

/// Free-writing surface.
///
/// Finish a word after `@` / `#` (at least 2 letters, matching a known
/// word) and the mind-map slides up as a bottom sheet, focused on that
/// word — pick what you need and copy it straight from the graph.
class SheetView extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  final VoidCallback onGraphChanged;

  const SheetView({
    super.key,
    required this.storage,
    required this.graph,
    required this.onGraphChanged,
  });

  @override
  State<SheetView> createState() => SheetViewState();
}

class SheetViewState extends State<SheetView> with WidgetsBindingObserver {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  final Debouncer _saver = Debouncer(const Duration(milliseconds: 500));

  bool _loaded = false;

  // Bottom-sheet session for the current tag.
  bool _sheetOpen = false;
  ValueNotifier<String>? _focusNote;
  String? _autoKey; // last "mode:word" opened or dismissed

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = TextEditingController();
    _focusNode = FocusNode();
    _controller.addListener(_onTextChanged);
    _load();
  }

  Future<void> _load() async {
    final text = await widget.storage.loadSheet();
    if (!mounted) return;
    _controller.removeListener(_onTextChanged);
    _controller.text = text;
    _controller.addListener(_onTextChanged);
    setState(() => _loaded = true);
  }

  @override
  void dispose() {
    // Save when the app closes / view is torn down so nothing is lost.
    widget.storage.saveSheet(_controller.text);
    _saver.dispose();
    _focusNote?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      widget.storage.saveSheet(_controller.text);
    }
  }

  void _onTextChanged() {
    // Silent continuous save, debounced ~500ms after last keystroke.
    final text = _controller.text;
    _saver.call(() => widget.storage.saveSheet(text));
    _updateLookup();
  }

  // ---- Tag detection (@word / #word before the cursor) ----
  ({String mode, String word})? _detectTrigger() {
    final text = _controller.text;
    final sel = _controller.selection;
    if (!sel.isValid || sel.baseOffset < 0) return null;
    final cursor = sel.baseOffset.clamp(0, text.length);
    // Walk backwards while chars are word chars.
    int i = cursor - 1;
    while (i >= 0 && _isWordChar(text[i])) {
      i--;
    }
    if (i < 0) return null;
    final sigil = text[i];
    if (sigil != '@' && sigil != '#') return null;
    // Sigil must start a token (start or whitespace/newline before it).
    if (i > 0 && !_isBoundary(text[i - 1])) return null;
    final word = text.substring(i + 1, cursor).toLowerCase();
    return (mode: sigil, word: word);
  }

  bool _isWordChar(String ch) => RegExp(r'[\w]').hasMatch(ch);
  bool _isBoundary(String ch) =>
      ch == ' ' || ch == '\n' || ch == '\t' || ch == '(' || ch == '"';

  void _updateLookup() {
    if (!_loaded || _sheetOpen) {
      // While the sheet is open, keep it focused on the tag being typed.
      if (_sheetOpen) _refocusFromTag();
      return;
    }
    final trig = _detectTrigger();
    if (trig == null) {
      _autoKey = null;
      return;
    }
    if (trig.word.length < 2) return; // let the word be finished first
    if (widget.graph.get(trig.word) == null) return; // still partial
    final key = '${trig.mode}:${trig.word}';
    if (key == _autoKey) return; // already shown / dismissed for this tag
    _autoKey = key;
    _openTagSheet(trig.mode, trig.word);
  }

  /// While the sheet stays open, follow the tag if it becomes another word.
  void _refocusFromTag() {
    final trig = _detectTrigger();
    if (trig == null || trig.word.length < 2) return;
    if (widget.graph.get(trig.word) == null) return;
    final key = '${trig.mode}:${trig.word}';
    _autoKey = key;
    if (_focusNote?.value != trig.word) _focusNote?.value = trig.word;
  }

  void _openTagSheet(String mode, String word) {
    _sheetOpen = true;
    _focusNote = ValueNotifier(word);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.78,
          child: TagGraphSheet(
            storage: widget.storage,
            graph: widget.graph,
            mode: mode,
            focus: _focusNote!,
            onGraphChanged: widget.onGraphChanged,
          ),
        ),
      ),
    ).then((_) {
      _sheetOpen = false;
      _focusNote?.dispose();
      _focusNote = null;
      // Hand the keyboard straight back so writing continues.
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// Called by the shell when the graph changes; the open sheet reads the
  /// same live graph object, so there is nothing to refresh here.
  void refreshGraph() {}

  /// Insert "@" or "#" at the cursor (toolbar buttons).
  /// If the cursor sits on a finished word, open its map instead.
  void _onSigilButton(String sigil) {
    final trig = _detectTrigger();
    if (trig != null &&
        trig.word.length >= 2 &&
        widget.graph.get(trig.word) != null) {
      _autoKey = null; // deliberate re-open, even for the same tag
      _updateLookup();
      return;
    }
    _insertSigil(sigil);
  }

  void _insertSigil(String sigil) {
    final text = _controller.text;
    final sel = _controller.selection;
    final cursor =
        sel.isValid ? sel.baseOffset.clamp(0, text.length) : text.length;
    final next =
        '${text.substring(0, cursor)}$sigil${text.substring(cursor)}';
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: cursor + 1),
    );
    _focusNode.requestFocus();
  }

  Widget _sigilButton(String label, String hint, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: PaperTheme.surface,
          border: Border.all(color: PaperTheme.lineThin),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    color: PaperTheme.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 4),
            Text(hint,
                style: const TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 10.5)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PaperTheme.paper,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 28, vertical: 18),
            decoration: BoxDecoration(
              // Subtle paper card over the paper background.
              color: const Color(0xFFEFE8D6),
              border:
                  Border.all(color: PaperTheme.lineThin, width: 1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _sigilButton(
                        '@', 'children', () => _onSigilButton('@')),
                    const SizedBox(width: 8),
                    _sigilButton(
                        '#', 'parents', () => _onSigilButton('#')),
                    const Spacer(),
                    const Text(
                      'finish the word — its map slides up',
                      style: TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 10.5),
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Divider(
                      height: 1, color: PaperTheme.lineThin),
                ),
                if (!_loaded)
                  const Center(
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
                else
                  TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    maxLines: null,
                    minLines: 18,
                    expands: false,
                    keyboardType: TextInputType.multiline,
                    onChanged: (_) => _onTextChanged(),
                    onTap: _updateLookup,
                    style: const TextStyle(
                      color: PaperTheme.ink,
                      fontSize: 16,
                      height: 1.6,
                      fontFamily: 'Georgia',
                    ),
                    cursorColor: PaperTheme.ink,
                    decoration: const InputDecoration(
                      hintText:
                          'Write freely…\n\nType @eat and the map of eat slides up — pick a word and copy it.',
                      hintStyle: TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 14),
                      border: InputBorder.none,
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
