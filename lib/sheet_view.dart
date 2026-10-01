import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_quill/flutter_quill.dart'
    show
        Attribute,
        BackgroundAttribute,
        Document,
        IconButtonData,
        QuillController,
        QuillEditor,
        QuillEditorConfig,
        QuillIconTheme,
        QuillSimpleToolbar,
        QuillSimpleToolbarConfig,
        StrikeThroughAttribute,
        StyleAttribute,
        getEmbedNode;
import 'package:flutter_quill_extensions/flutter_quill_extensions.dart';

import 'graph_model.dart';
import 'storage.dart';
import 'tag_sheet.dart';
import 'theme.dart';

/// Fill for graph words with no chosen card color (a touch deeper
/// than paper so it stays visible).
const String _matchDefaultHex = '#d9cfb0';

/// Old managed fills from earlier versions; still lifted when stale.
const Set<String> _legacyMatchHex = {'#c6efce', '#f69697'};

String _colorHex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// A graph word's highlight: its card color, or the default fill.
String _highlightHexFor(WordGraph graph, String word) {
  final c = graph.get(word)?.color;
  if (c == null) return _matchDefaultHex;
  return _colorHex(c);
}

/// All fills this pass manages (current cards + legacy leftovers).
Set<String> _managedHexes(WordGraph graph) {
  final out = <String>{_matchDefaultHex, ..._legacyMatchHex};
  for (final n in graph.nodes.values) {
    if (n.color != null) out.add(_colorHex(n.color!));
  }
  return out;
}

/// Whole-word, case-insensitive matches with the graph word each hit.
List<({int start, int end, String word})> findGraphMatches(
    String text, List<String> words) {
  final result = <({int start, int end, String word})>[];
  final keys = words.where((w) => w.trim().isNotEmpty).toList();
  if (keys.isEmpty || text.isEmpty) return result;
  final lower = <String, String>{};
  for (final k in keys) {
    lower.putIfAbsent(k.toLowerCase(), () => k);
  }
  final escaped = lower.keys.map(RegExp.escape).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final re =
      RegExp('\\b(?:${escaped.join('|')})\\b', caseSensitive: false);
  for (final m in re.allMatches(text)) {
    result.add(
        (start: m.start, end: m.end, word: lower[m.group(0)!.toLowerCase()]!));
  }
  return result;
}

/// Writing view: titled sessions in a left rail, a styled editor
/// (bold / italic / underline / text color / highlight / headers / lists)
/// and @ mentions — typing @ pops up the words from the mind-map,
/// tapping one inserts it into the text.
class SheetView extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;

  /// Forbidden words, shared live with the banned page.
  final List<String> forbidden;
  final VoidCallback onGraphChanged;

  const SheetView({
    super.key,
    required this.storage,
    required this.graph,
    required this.forbidden,
    required this.onGraphChanged,
  });

  @override
  State<SheetView> createState() => SheetViewState();
}

class SheetViewState extends State<SheetView> with WidgetsBindingObserver {
  late QuillController _quill;
  late final FocusNode _focusNode;
  late final ScrollController _scrollCtrl;
  final TextEditingController _titleCtrl = TextEditingController();
  final Debouncer _saver = Debouncer(const Duration(milliseconds: 500));
  final Debouncer _highlighter = Debouncer(const Duration(milliseconds: 600));
  bool _applyingHighlight = false;

  List<WritingSession> _sessions = [];
  String? _activeId;
  bool _loaded = false;
  bool _switching = false; // guards programmatic controller updates
  bool _onImage = false; // caret sits on an image embed

  // Mention popup state (@frag -> matching words).
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _editorKey = GlobalKey();
  OverlayEntry? _overlay;
  List<String> _matches = [];
  String _frag = '';
  Offset _popupOffset = const Offset(0, 40);
  double _editorWidth = 600;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _quill = QuillController.basic();
    _focusNode = FocusNode();
    _scrollCtrl = ScrollController();
    _quill.addListener(_onDocChanged);
    _titleCtrl.addListener(_onTitleChanged);
    _boot();
  }

  Future<void> _boot() async {
    var sessions = await widget.storage.loadSessions();
    // One-time upgrade: fold the old single sheet.txt into a session.
    final legacy = await widget.storage.takeLegacySheet();
    if (legacy != null) {
      final created =
          await widget.storage.createSession(legacy.title);
      await widget.storage
          .saveSession(created.id, legacy.title, legacy.deltaJson);
      sessions = await widget.storage.loadSessions();
    }
    if (sessions.isEmpty) {
      final created =
          await widget.storage.createSession('First notes');
      sessions = [created];
    }
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _activeId = sessions.first.id;
      _loaded = true;
    });
    await _openSession(sessions.first.id);
  }

  Future<void> _openSession(String id) async {
    await _saveNow(); // never lose the session we leave
    final delta = await widget.storage.loadSessionDelta(id);
    if (!mounted) return;
    _switching = true;
    try {
      if (delta == null || delta.isEmpty) {
        _quill.document = Document();
      } else {
        _quill.document =
            Document.fromJson(jsonDecode(delta) as List);
      }
      final session =
          _sessions.firstWhere((s) => s.id == id);
      _titleCtrl.text = session.title;
      setState(() => _activeId = id);
    } catch (_) {
      _quill.document = Document();
    } finally {
      _switching = false;
    }
  }

  Future<void> _newSession() async {
    await _saveNow();
    final created = await widget.storage.createSession(
        'Untitled ${_sessions.length + 1}');
    if (!mounted) return;
    setState(() {
      _sessions = [created, ..._sessions];
    });
    await _openSession(created.id);
  }

  Future<void> _deleteSession(String id) async {
    await widget.storage.deleteSession(id);
    if (!mounted) return;
    final remaining =
        _sessions.where((s) => s.id != id).toList();
    if (remaining.isEmpty) {
      final created =
          await widget.storage.createSession('First notes');
      setState(() {
        _sessions = [created];
      });
      await _openSession(created.id);
    } else {
      setState(() => _sessions = remaining);
      if (_activeId == id) await _openSession(remaining.first.id);
    }
  }

  String _deltaJson() {
    try {
      return jsonEncode(_quill.document.toDelta().toJson());
    } catch (_) {
      return '';
    }
  }

  Future<void> _saveNow() async {
    final id = _activeId;
    if (id == null || !_loaded) return;
    await widget.storage
        .saveSession(id, _titleCtrl.text.trim(), _deltaJson());
  }

  void _onDocChanged() {
    if (_switching || !_loaded || _activeId == null) return;
    if (_applyingHighlight) return; // our own green paint, not typing
    final id = _activeId!;
    final title = _titleCtrl.text.trim();
    _saver.call(() => widget.storage.saveSession(id, title, _deltaJson()));
    final onImg = _caretOnImage();
    if (onImg != _onImage) setState(() => _onImage = onImg);
    _updateLookup();
    _highlighter.call(_applyHighlight);
  }

  /// Paint every graph word in its card color and cross every forbidden
  /// word; lift marks that no longer match. Only touches managed fills —
  /// the user's other colors are left alone (the strike tool stays off
  /// the toolbar so every strike in the text is auto-managed).
  void _applyHighlight() {
    if (!mounted || _switching || !_loaded || _applyingHighlight) return;
    _applyingHighlight = true;
    try {
      final text = _quill.document.toPlainText();
      final matches =
          findGraphMatches(text, widget.graph.sortedKeys());
      final greenRanges = [
        for (final m in matches)
          (
            start: m.start,
            end: m.end,
            hex: _highlightHexFor(widget.graph, m.word),
          )
      ];
      final strikeRanges = findGraphMatches(text, widget.forbidden)
          .map((m) => (m.start, m.end))
          .toList();
      final current = _currentMarks(_managedHexes(widget.graph));
      bool covers(List<(int, int)> list, int s, int e) {
        for (final r in list) {
          if (r.$1 <= s && r.$2 >= e) return true;
        }
        return false;
      }

      bool coveredSameColor(
          List<({int start, int end, String hex})> list,
          int s,
          int e,
          String hex) {
        for (final r in list) {
          if (r.start <= s && r.end >= e && r.hex == hex) return true;
        }
        return false;
      }

      for (final r in current.green) {
        if (!coveredSameColor(greenRanges, r.start, r.end, r.hex)) {
          _quill.formatText(
              r.start, r.end - r.start, const BackgroundAttribute(null));
        }
      }
      for (final n in greenRanges) {
        if (!coveredSameColor(current.green, n.start, n.end, n.hex)) {
          _quill.formatText(
              n.start, n.end - n.start, BackgroundAttribute(n.hex));
        }
      }
      for (final r in current.strike) {
        if (!covers(strikeRanges, r.$1, r.$2)) {
          _quill.formatText(r.$1, r.$2 - r.$1,
              Attribute.clone(Attribute.strikeThrough, null));
        }
      }
      for (final r in strikeRanges) {
        if (!covers(current.strike, r.$1, r.$2)) {
          _quill.formatText(
              r.$1, r.$2 - r.$1, const StrikeThroughAttribute());
        }
      }
    } catch (_) {
      // Never interrupt writing for highlight housekeeping.
    } finally {
      _applyingHighlight = false;
    }
  }
  /// Live ranges currently wearing a managed fill / a strike.
  ({List<({int start, int end, String hex})> green, List<(int, int)> strike})
      _currentMarks(Set<String> managed) {
    final green = <({int start, int end, String hex})>[];
    final strike = <(int, int)>[];
    var pos = 0;
    try {
      for (final op in _quill.document.toDelta().toList()) {
        final data = op.data;
        final len = data is String ? data.length : 1;
        final attrs = op.attributes;
        final bg = attrs == null ? null : attrs['background'];
        if (bg != null &&
            managed.contains(bg.toString().toLowerCase())) {
          green.add(
              (start: pos, end: pos + len, hex: bg.toString().toLowerCase()));
        }
        if (attrs != null && attrs['strike'] == true) {
          strike.add((pos, pos + len));
        }
        pos += len;
      }
    } catch (_) {}
    return (green: green, strike: strike);
  }

  /// True when the caret sits right on an image embed.
  bool _caretOnImage() {
    try {
      final res = getEmbedNode(_quill, _quill.selection.start);
      return res.value.value.type == 'image';
    } catch (_) {
      return false;
    }
  }

  /// Move the image at the caret left / center / right.
  void _alignImage(String align) {
    try {
      final res = getEmbedNode(_quill, _quill.selection.start);
      if (res.value.value.type != 'image') return;
      final cur = res.value.style.attributes['style']?.value
              ?.toString() ??
          '';
      final parts = <String, String>{};
      for (final d in cur.split(';')) {
        final i = d.indexOf(':');
        if (i > 0) {
          parts[d.substring(0, i).trim()] =
              d.substring(i + 1).trim();
        }
      }
      parts['alignment'] = align;
      final next =
          parts.entries.map((e) => '${e.key}: ${e.value}').join('; ');
      _quill.formatText(res.offset, 1, StyleAttribute(next));
    } catch (_) {}
  }

  void _onTitleChanged() {
    if (_switching || !_loaded || _activeId == null) return;
    final title = _titleCtrl.text.trim();
    for (final s in _sessions) {
      if (s.id == _activeId) {
        s.title = title.isEmpty ? 'Untitled' : title;
        break;
      }
    }
    final id = _activeId!;
    _saver.call(() => widget.storage.saveSession(id, title, _deltaJson()));
    setState(() {}); // refresh rail titles
  }

  @override
  void dispose() {
    _saveNow();
    _saver.dispose();
    _highlighter.dispose();
    _removeOverlay();
    WidgetsBinding.instance.removeObserver(this);
    _quill.removeListener(_onDocChanged);
    _quill.dispose();
    _titleCtrl.dispose();
    _focusNode.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _saveNow();
    }
  }

  // ---- Mention picker (@frag before the cursor) ----
  // Returns the fragment (possibly empty) or null when no @ tag applies.
  String? _detectMention() {
    final text = _quill.document.toPlainText();
    final sel = _quill.selection;
    if (!sel.isValid || sel.baseOffset < 0) return null;
    final cursor = sel.baseOffset.clamp(0, text.length);
    int i = cursor - 1;
    while (i >= 0 && _isWordChar(text[i])) {
      i--;
    }
    if (i < 0 || text[i] != '@') return null;
    if (i > 0 && !_isBoundary(text[i - 1])) return null;
    return text.substring(i + 1, cursor).toLowerCase();
  }

  bool _isWordChar(String ch) => RegExp(r'[\w]').hasMatch(ch);
  bool _isBoundary(String ch) =>
      ch == ' ' || ch == '\n' || ch == '\t' || ch == '(' || ch == '"';

  void _updateLookup() {
    if (!_loaded || _activeId == null) return;
    // Never hijack an active text selection with the popup.
    if (_quill.selection.start != _quill.selection.end) {
      _removeOverlay();
      return;
    }
    final frag = _detectMention();
    if (frag == null) {
      _removeOverlay();
      return;
    }
    final all = widget.graph.sortedKeys();
    final starts = [
      for (final k in all)
        if (k.startsWith(frag)) k
    ];
    final contains = [
      for (final k in all)
        if (!k.startsWith(frag) && k.contains(frag)) k
    ];
    _frag = frag;
    _matches = [...starts, ...contains];
    if (_matches.isEmpty) {
      _removeOverlay();
      return;
    }
    _estimateCaretOffset();
    if (_overlay == null) {
      _showOverlay();
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  // Rough caret position so the popup floats near the cursor.
  void _estimateCaretOffset() {
    try {
      final box =
          _editorKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) _editorWidth = box.size.width;
      const lineHeight = 27.0;
      const charWidth = 8.0;
      final text = _quill.document.toPlainText();
      final cursor =
          _quill.selection.baseOffset.clamp(0, text.length);
      final before = text.substring(0, cursor);
      final lines = before.split('\n');
      final line = lines.length - 1;
      final col = lines.isEmpty ? 0 : lines.last.length;
      final x = (10 + col * charWidth)
          .clamp(10, (_editorWidth - 220).clamp(10, 1e6))
          .toDouble();
      _popupOffset = Offset(x, 8 + (line + 1) * lineHeight);
    } catch (_) {
      _popupOffset = const Offset(10, 40);
    }
  }

  void _showOverlay() {
    _removeOverlay();
    final overlay = Overlay.of(context);
    _overlay = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // Taps anywhere else dismiss; taps on the popup reach it first.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _removeOverlay,
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: _popupOffset,
            child: Align(
              alignment: Alignment.topLeft,
              child: _buildPicker(),
            ),
          ),
        ],
      ),
    );
    overlay.insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  /// Tiny floating mention list — fixed small size, never a big panel.
  Widget _buildPicker() {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 210,
        decoration: BoxDecoration(
          color: const Color(0xFFF4EEDF),
          border: Border.all(color: PaperTheme.lineThin),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3E3A31).withValues(alpha: 0.14),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _frag.isEmpty ? 'words…' : 'matching "$_frag"…',
                      style: const TextStyle(
                        color: PaperTheme.inkSoft,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  InkWell(
                    onTap: _removeOverlay,
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close,
                          size: 13, color: PaperTheme.inkSoft),
                    ),
                  ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 168),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(
                    horizontal: 5, vertical: 2),
                itemCount: _matches.length,
                itemBuilder: (context, i) {
                  final w = _matches[i];
                  return GestureDetector(
                    // Tap inserts the word; long-press copies it.
                    onTap: () => _insertWord(w),
                    onLongPress: () => _copyWord(w),
                    child: Container(
                      margin:
                          const EdgeInsets.symmetric(vertical: 1),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        w,
                        style: const TextStyle(
                          color: PaperTheme.ink,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 3, 12, 8),
              child: Text(
                'tap to insert · long-press to copy',
                style: TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 9),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Replace "@frag" at the cursor with the picked word plus a space,
  /// then slide the map up already scrolled to that word.
  void _insertWord(String word) {
    final text = _quill.document.toPlainText();
    final cursor =
        _quill.selection.baseOffset.clamp(0, text.length);
    int i = cursor - 1;
    while (i >= 0 && _isWordChar(text[i])) {
      i--;
    }
    if (i < 0 || text[i] != '@') {
      _removeOverlay();
      return;
    }
    _quill.replaceText(i, cursor - i, '$word ',
        TextSelection.collapsed(offset: i + word.length + 1));
    _removeOverlay();
    _focusNode.requestFocus();
    _openMapSheet(word);
  }

  void _openMapSheet(String word) {
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
            word: word,
            onGraphChanged: widget.onGraphChanged,
          ),
        ),
      ),
    ).then((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _copyWord(String word) {
    Clipboard.setData(ClipboardData(text: word));
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied "$word" — ready to paste.'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // Bottom-sheet tag flow removed; @mentions insert the word directly.

  /// Called by the shell when the graph changes; the popup reads the live
  /// graph object, so a refresh is just a re-lookup (plus re-highlight).
  void refreshGraph() {
    if (_overlay != null) _updateLookup();
    _highlighter.call(_applyHighlight);
  }

  /// Test hook: types text at the end of the note as if the user typed it.
  @visibleForTesting
  void typeForTest(String text) {
    final at = _quill.document.length - 1;
    _quill.replaceText(at, 0, text,
        TextSelection.collapsed(offset: at + text.length));
  }

  /// Test hook: current plain text of the note.
  @visibleForTesting
  String debugPlainText() => _quill.document.toPlainText();

  /// Test hook: current document delta as JSON.
  @visibleForTesting
  String debugDeltaJson() {
    try {
      return jsonEncode(_quill.document.toDelta().toJson());
    } catch (_) {
      return '';
    }
  }

  /// Insert "@" at the cursor (toolbar button).
  void _onAtButton() {
    final pos = _quill.selection.baseOffset;
    final len = _quill.document.length;
    final at = pos < 0 ? len - 1 : pos.clamp(0, len - 1);
    _quill.replaceText(at, 0, '@', null);
    _focusNode.requestFocus();
  }

  String _dateLabel(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (dt.year == now.year &&
        dt.month == now.month &&
        dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PaperTheme.paper,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Sessions rail.
          Container(
            width: 216,
            decoration: const BoxDecoration(
              color: PaperTheme.paperDark,
              border: Border(
                  right: BorderSide(color: PaperTheme.lineThin)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 6, 4),
                  child: Row(
                    children: [
                      const Text('NOTES',
                          style: TextStyle(
                              color: PaperTheme.inkSoft,
                              fontSize: 11,
                              letterSpacing: 1.2)),
                      const Spacer(),
                      IconButton(
                        tooltip: 'New note',
                        onPressed: _loaded ? _newSession : null,
                        icon: const Icon(Icons.add,
                            size: 18, color: PaperTheme.ink),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: !_loaded
                      ? const Center(
                          child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2)))
                      : ListView.builder(
                          itemCount: _sessions.length,
                          itemBuilder: (context, i) {
                            final s = _sessions[i];
                            final active = s.id == _activeId;
                            return InkWell(
                              onTap: () {
                                if (s.id != _activeId) {
                                  _openSession(s.id);
                                }
                              },
                              borderRadius:
                                  BorderRadius.circular(12),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: active
                                      ? PaperTheme.chip
                                      : Colors.transparent,
                                  borderRadius:
                                      BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(s.title,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: PaperTheme.ink,
                                                fontSize: 13,
                                                fontWeight: active
                                                    ? FontWeight.w600
                                                    : FontWeight.normal,
                                              )),
                                          Text(_dateLabel(s.updatedAt),
                                              style: const TextStyle(
                                                  color: PaperTheme
                                                      .inkSoft,
                                                  fontSize: 10)),
                                        ],
                                      ),
                                    ),
                                    InkWell(
                                      onTap: () =>
                                          _deleteSession(s.id),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      child: const Padding(
                                        padding: EdgeInsets.all(4),
                                        child: Icon(Icons.close,
                                            size: 13,
                                            color:
                                                PaperTheme.inkSoft),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          // Editor side.
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: 780),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFE8D6),
                      border: Border.all(
                          color: PaperTheme.lineThin, width: 1),
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
                              // Title of this writing session.
                              TextField(
                                controller: _titleCtrl,
                                style: const TextStyle(
                                  color: PaperTheme.ink,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                                cursorColor: PaperTheme.ink,
                                decoration: const InputDecoration(
                                  hintText: 'Untitled',
                                  hintStyle: TextStyle(
                                      color: PaperTheme.inkSoft),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding:
                                      EdgeInsets.symmetric(
                                          vertical: 4),
                                ),
                              ),
                              Row(
                                children: [
                                  _sigilButton('@', 'mention',
                                      _onAtButton),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'type @ to mention a word from the map',
                                      textAlign: TextAlign.right,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: PaperTheme.inkSoft,
                                          fontSize: 10.5),
                                    ),
                                  ),
                                ],
                              ),
                              // Styling tools, kept in the paper palette.
                              QuillSimpleToolbar(
                                controller: _quill,
                                config: QuillSimpleToolbarConfig(
                                  embedButtons:
                                      FlutterQuillEmbeds.toolbarButtons(),
                                  multiRowsDisplay: false,
                                  showDividers: false,
                                  showFontFamily: false,
                                  showFontSize: false,
                                  showSmallButton: false,
                                  showLineHeightButton: false,
                                  showStrikeThrough: false,
                                  showInlineCode: false,
                                  showColorButton: true,
                                  showBackgroundColorButton: true,
                                  showClearFormat: true,
                                  showAlignmentButtons: false,
                                  showHeaderStyle: true,
                                  showListNumbers: true,
                                  showListBullets: true,
                                  showListCheck: false,
                                  showCodeBlock: false,
                                  showQuote: true,
                                  showIndent: false,
                                  showLink: true,
                                  showSearchButton: false,
                                  showSubscript: false,
                                  showSuperscript: false,
                                  color: Colors.transparent,
                                  iconTheme: QuillIconTheme(
                                    iconButtonUnselectedData:
                                        IconButtonData(
                                            color:
                                                PaperTheme.inkSoft),
                                    iconButtonSelectedData:
                                        IconButtonData(
                                            color: PaperTheme.ink),
                                  ),
                                ),
                              ),
                              const Divider(
                                  height: 12,
                                  color: PaperTheme.lineThin),
                              // Image tools appear while the caret is on a picture.
                              if (_onImage)
                                Padding(
                                  padding: const EdgeInsets.only(
                                      top: 2, bottom: 6),
                                  child: Row(
                                    children: [
                                      const Text('Image: ',
                                          style: TextStyle(
                                              color:
                                                  PaperTheme.inkSoft,
                                              fontSize: 11)),
                                      _alignBtn(
                                          'Left',
                                          'centerLeft',
                                          Icons.format_align_left),
                                      _alignBtn(
                                          'Center',
                                          'center',
                                          Icons.format_align_center),
                                      _alignBtn(
                                          'Right',
                                          'centerRight',
                                          Icons.format_align_right),
                                    ],
                                  ),
                                ),
                              Expanded(
                                child: CompositedTransformTarget(
                                  link: _layerLink,
                                  child: Container(
                                    key: _editorKey,
                                    child: QuillEditor.basic(
                                      controller: _quill,
                                      focusNode: _focusNode,
                                      scrollController: _scrollCtrl,
                                      config: QuillEditorConfig(
                                        embedBuilders: kIsWeb
                                            ? FlutterQuillEmbeds
                                                .editorWebBuilders()
                                            : FlutterQuillEmbeds
                                                .editorBuilders(),
                                        // Keep single-line: quill embeds the
                                        // placeholder raw in JSON (newlines crash it).
                                        placeholder:
                                            'Write freely… type @ to mention a word.',
                                        autoFocus: true,
                                        scrollable: true,
                                        padding: EdgeInsets.symmetric(
                                            vertical: 8),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _alignBtn(String label, String align, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: () => _alignImage(align),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: PaperTheme.surface,
            border: Border.all(color: PaperTheme.lineThin),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: PaperTheme.ink),
              const SizedBox(width: 3),
              Text(label,
                  style: const TextStyle(
                      color: PaperTheme.ink, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
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
}
