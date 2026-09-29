import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'graph_model.dart';
import 'storage.dart';
import 'theme.dart';

/// Free-writing surface.
///
/// Typing `@word` lists children of `word`; typing `#word` lists parents.
/// The dropdown is an Overlay anchored with CompositedTransformFollower near
/// the text cursor. Left click drills down into children, right click copies.
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
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _fieldKey = GlobalKey();
  final Debouncer _saver = Debouncer(const Duration(milliseconds: 500));

  bool _loaded = false;

  // Popup state — a small navigable graph, never auto-inserts into the sheet.
  OverlayEntry? _overlay;
  String? _triggerMode; // '@' children or '#' parents
  String _rootWord = '';
  List<String> _navStack = []; // drill path; last = currently shown word
  List<String> _items = [];
  Offset _dropdownOffset = const Offset(0, 60);
  double _editorWidth = 600;

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
    _removeOverlay();
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

  void _onSelectionChanged() => _updateLookup();

  // ---- Trigger detection ----
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
    if (word.isEmpty) return null;
    return (mode: sigil, word: word);
  }

  bool _isWordChar(String ch) => RegExp(r'[\w]').hasMatch(ch);
  bool _isBoundary(String ch) =>
      ch == ' ' || ch == '\n' || ch == '\t' || ch == '(' || ch == '"';

  void _updateLookup() {
    if (!_loaded) return;
    final trig = _detectTrigger();
    if (trig == null) {
      _removeOverlay();
      return;
    }
    final mode = trig.mode;
    final word = trig.word;
    // New root typed -> reset navigation.
    if (mode != _triggerMode || word != _rootWord) {
      _triggerMode = mode;
      _rootWord = word;
      _navStack = [word];
      _items = mode == '@'
          ? widget.graph.childrenOf(word)
          : widget.graph.parentsOf(word);
    } else {
      // Same root: refresh in case graph changed elsewhere.
      if (_navStack.length == 1) {
        _items = mode == '@'
            ? widget.graph.childrenOf(word)
            : widget.graph.parentsOf(word);
      } else {
        _items = widget.graph.childrenOf(_navStack.last);
      }
    }
    _estimateCaretOffset();
    _showOrUpdateOverlay();
  }

  // Approximate the caret position so the follower sits next to the cursor.
  void _estimateCaretOffset() {
    try {
      final ctx = _fieldKey.currentContext;
      if (ctx != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null) _editorWidth = box.size.width;
      }
      const lineHeight = 26.0;
      const charWidth = 8.2;
      final cursor = _controller.selection.baseOffset
          .clamp(0, _controller.text.length);
      final before = _controller.text.substring(0, cursor);
      final lines = before.split('\n');
      final line = lines.length - 1;
      final col = lines.isEmpty ? 0 : lines.last.length;
      double x = 12 + col * charWidth;
      x = x.clamp(12, (_editorWidth - 280).clamp(12, 1e6)).toDouble();
      final y = 12 + (line + 1) * lineHeight;
      _dropdownOffset = Offset(x, y);
    } catch (_) {
      _dropdownOffset = const Offset(12, 60);
    }
  }

  // ---- Overlay ----
  void _showOrUpdateOverlay() {
    _removeOverlay();
    final overlay = Overlay.of(context);
    _overlay = OverlayEntry(builder: (context) {
      return CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: _dropdownOffset,
        child: Material(
          elevation: 2,
          color: Colors.transparent,
          child: _buildDropdown(),
        ),
      );
    });
    overlay.insert(_overlay!);
  }

  void _refreshOverlay() {
    _overlay?.markNeedsBuild();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  // ---- Dropdown interactions ----
  void _drillDown(String word) {
    // Left click: show words linked UNDER that word (its children).
    final kids = widget.graph.childrenOf(word);
    if (kids.isEmpty) return; // nothing below -> do nothing at all.
    setState(() {
      _navStack = [..._navStack, word.toLowerCase()];
      _items = kids;
    });
    _refreshOverlay();
  }

  void _goBack() {
    if (_navStack.length <= 1) return;
    final next = _navStack.sublist(0, _navStack.length - 1);
    final showing = next.last;
    List<String> items;
    if (next.length == 1) {
      items = _triggerMode == '@'
          ? widget.graph.childrenOf(showing)
          : widget.graph.parentsOf(showing);
    } else {
      items = widget.graph.childrenOf(showing);
    }
    setState(() {
      _navStack = next;
      _items = items;
    });
    _refreshOverlay();
  }

  void _copyWord(String word) {
    Clipboard.setData(ClipboardData(text: word));
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied "$word" — paste it manually where you like.'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _buildDropdown() {
    final showing = _navStack.isEmpty ? _rootWord : _navStack.last;
    final kindLabel = _navStack.length <= 1
        ? (_triggerMode == '@' ? 'children of' : 'parents of')
        : 'children of';
    return Container(
      width: 260,
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: PaperTheme.surface,
        border: Border.all(color: PaperTheme.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: const BoxDecoration(
              color: PaperTheme.card,
              borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
            ),
            child: Row(
              children: [
                if (_navStack.length > 1)
                  InkWell(
                    onTap: _goBack,
                    child: const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.arrow_back,
                          size: 16, color: PaperTheme.inkSoft),
                    ),
                  ),
                Expanded(
                  child: Text(
                    '$kindLabel "$showing"',
                    style: const TextStyle(
                      color: PaperTheme.ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                InkWell(
                  onTap: _removeOverlay,
                  child: const Icon(Icons.close,
                      size: 16, color: PaperTheme.inkSoft),
                ),
              ],
            ),
          ),
          if (_navStack.length > 1)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                _navStack.join(' › '),
                style: const TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Flexible(
            child: _items.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'No words here yet.\nAdd them in the Graph view.',
                      style: TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final w = _items[i];
                      final hasKids =
                          widget.graph.childrenOf(w).isNotEmpty;
                      return GestureDetector(
                        // Left click drills down, never inserts text.
                        onTap: () => _drillDown(w),
                        // Right click copies for manual pasting.
                        onSecondaryTap: () => _copyWord(w),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                  color: PaperTheme.lineThin, width: 0.5),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  w,
                                  style: const TextStyle(
                                    color: PaperTheme.ink,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              if (hasKids)
                                const Icon(Icons.chevron_right,
                                    size: 16,
                                    color: PaperTheme.inkSoft),
                              InkWell(
                                onTap: () => _copyWord(w),
                                child: const Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: Icon(Icons.copy,
                                      size: 14,
                                      color: PaperTheme.inkSoft),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              'Left-click: explore deeper · Right-click: copy',
              style:
                  TextStyle(color: PaperTheme.inkSoft, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  /// Called by the shell when the graph changes so an open popup refreshes.
  void refreshGraph() {
    if (_overlay != null) _updateLookup();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: Container(
        color: PaperTheme.paper,
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 28, vertical: 24),
              decoration: BoxDecoration(
                // Subtle paper card over the paper background.
                color: const Color(0xFFEFE8D6),
                border:
                    Border.all(color: PaperTheme.lineThin, width: 1),
                borderRadius: BorderRadius.circular(4),
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
                  : TextField(
                      key: _fieldKey,
                      controller: _controller,
                      focusNode: _focusNode,
                      autofocus: true,
                      maxLines: null,
                      minLines: 18,
                      expands: false,
                      keyboardType: TextInputType.multiline,
                      onChanged: (_) => _onTextChanged(),
                      onTap: _onSelectionChanged,
                      onTapOutside: (_) => _removeOverlay(),
                      style: const TextStyle(
                        color: PaperTheme.ink,
                        fontSize: 16,
                        height: 1.6,
                        fontFamily: 'Georgia',
                      ),
                      cursorColor: PaperTheme.ink,
                      decoration: const InputDecoration(
                        hintText:
                            'Write freely…\n\nType @eat for children, #eat for parents.',
                        hintStyle: TextStyle(
                            color: PaperTheme.inkSoft, fontSize: 14),
                        border: InputBorder.none,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
