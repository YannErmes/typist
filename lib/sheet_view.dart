import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show
        Document,
        IconButtonData,
        QuillController,
        QuillEditor,
        QuillEditorConfig,
        QuillIconTheme,
        QuillSimpleToolbar,
        QuillSimpleToolbarConfig,
        StyleAttribute,
        getEmbedNode;
import 'package:flutter_quill_extensions/flutter_quill_extensions.dart';

import 'graph_model.dart';
import 'storage.dart';
import 'tag_sheet.dart';
import 'theme.dart';

/// Writing view: titled sessions in a left rail, a styled editor
/// (bold / italic / underline / text color / highlight / headers / lists)
/// and the @ / # tag flow — finishing a known word slides the mind-map
/// up as a bottom sheet focused on that word.
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
  late QuillController _quill;
  late final FocusNode _focusNode;
  late final ScrollController _scrollCtrl;
  final TextEditingController _titleCtrl = TextEditingController();
  final Debouncer _saver = Debouncer(const Duration(milliseconds: 500));

  List<WritingSession> _sessions = [];
  String? _activeId;
  bool _loaded = false;
  bool _switching = false; // guards programmatic controller updates
  bool _onImage = false; // caret sits on an image embed

  // Bottom-sheet session for the current tag.
  bool _sheetOpen = false;
  ValueNotifier<String>? _focusNote;
  String? _autoKey; // last "mode:word" opened or dismissed

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
    final id = _activeId!;
    final title = _titleCtrl.text.trim();
    _saver.call(() => widget.storage.saveSession(id, title, _deltaJson()));
    final onImg = _caretOnImage();
    if (onImg != _onImage) setState(() => _onImage = onImg);
    _updateLookup();
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
    _focusNote?.dispose();
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

  // ---- Tag detection (@word / #word before the cursor) ----
  ({String mode, String word})? _detectTrigger() {
    final text = _quill.document.toPlainText();
    final sel = _quill.selection;
    if (!sel.isValid || sel.baseOffset < 0) return null;
    final cursor = sel.baseOffset.clamp(0, text.length);
    int i = cursor - 1;
    while (i >= 0 && _isWordChar(text[i])) {
      i--;
    }
    if (i < 0) return null;
    final sigil = text[i];
    if (sigil != '@' && sigil != '#') return null;
    if (i > 0 && !_isBoundary(text[i - 1])) return null;
    final word = text.substring(i + 1, cursor).toLowerCase();
    return (mode: sigil, word: word);
  }

  bool _isWordChar(String ch) => RegExp(r'[\w]').hasMatch(ch);
  bool _isBoundary(String ch) =>
      ch == ' ' || ch == '\n' || ch == '\t' || ch == '(' || ch == '"';

  void _updateLookup() {
    if (!_loaded || _activeId == null) return;
    // Never hijack an active text selection with the map sheet.
    if (_quill.selection.start != _quill.selection.end) return;
    if (_sheetOpen) {
      _refocusFromTag();
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
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// Called by the shell when the graph changes; the open sheet reads the
  /// same live graph object, so there is nothing to refresh here.
  void refreshGraph() {}

  /// Test hook: types text at the end of the note as if the user typed it.
  @visibleForTesting
  void typeForTest(String text) {
    final at = _quill.document.length - 1;
    _quill.replaceText(at, 0, text,
        TextSelection.collapsed(offset: at + text.length));
  }

  void _onSigilButton(String sigil) {
    final trig = _detectTrigger();
    if (trig != null &&
        trig.word.length >= 2 &&
        widget.graph.get(trig.word) != null) {
      _autoKey = null; // deliberate re-open, even for the same tag
      _updateLookup();
      return;
    }
    // Insert the sigil at the cursor.
    final pos = _quill.selection.baseOffset;
    final len = _quill.document.length;
    final at = pos < 0 ? len - 1 : pos.clamp(0, len - 1);
    _quill.replaceText(at, 0, sigil, null);
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
                                  _sigilButton('@', 'children',
                                      () => _onSigilButton('@')),
                                  const SizedBox(width: 8),
                                  _sigilButton('#', 'parents',
                                      () => _onSigilButton('#')),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'finish the word — its map slides up',
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
                                        'Write freely… type @eat to open its map.',
                                    autoFocus: true,
                                    scrollable: true,
                                    padding: EdgeInsets.symmetric(
                                        vertical: 8),
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
