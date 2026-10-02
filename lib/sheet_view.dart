import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_quill/flutter_quill.dart'
    show
        Attribute,
        BackgroundAttribute,
        ColorAttribute,
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

/// Banned words wear this red text with their cross-out line.
const String _banRedHex = '#b3261e';

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

/// Words typed: letter/digit runs, keeping mid-word apostrophes together.
int countWords(String text) {
  return RegExp(r"[\p{L}\p{N}]+(?:'[\p{L}\p{N}]+)?", unicode: true)
      .allMatches(text)
      .length;
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

  /// Reused for every folder dialog. Never disposed mid-flight: disposing a
  /// dialog controller while its route animates out trips rebuilds that
  /// still reference it (red screen). Disposed once with this state.
  final TextEditingController _folderCtrl = TextEditingController();
  final Debouncer _saver = Debouncer(const Duration(milliseconds: 500));
  final Debouncer _highlighter = Debouncer(const Duration(milliseconds: 600));
  bool _applyingHighlight = false;

  List<WritingSession> _sessions = [];
  String? _activeId;
  bool _loaded = false;
  bool _switching = false; // guards programmatic controller updates
  bool _onImage = false; // caret sits on an image embed

  /// Explicitly created folders (so empties survive restarts too).
  final Set<String> _knownFolders = {};

  /// Collapsed folders in the rail (everything expanded by default).
  final Set<String> _collapsedFolders = {};

  /// Live word count of the open note.
  final ValueNotifier<int> _wordCount = ValueNotifier(0);

  /// Already-handled #[phrase] tags this run, so retyping never fires twice.
  final Set<String> _handledPhrase = {};

  // Mention popup state (@frag -> matching words, #frag -> chooser).
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _editorKey = GlobalKey();
  OverlayEntry? _overlay;
  String _popupKind = 'mention'; // 'mention' or 'hash'
  List<String> _matches = [];
  String _frag = '';
  String _hashFrag = '';
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
    final storedFolders = await widget.storage.loadFolders();
    _knownFolders.addAll(storedFolders);
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
      _loaded = true;
    });
    // NOTE: _activeId stays null until _openSession loads the doc.
    // Setting it early would make the entry saveNow() below overwrite
    // the newest note with the still-empty editor (data loss).
    await _openSession(sessions.first.id);
  }

  int _openGen = 0;

  Future<void> _openSession(String id) async {
    final gen = ++_openGen; // stale runs (rapid switches) must not win
    await _saveNow(); // never lose the session we leave
    final delta = await widget.storage.loadSessionDelta(id);
    if (!mounted || gen != _openGen) return;
    _switching = true;
    try {
      if (delta == null || delta.isEmpty) {
        _quill.document = Document();
      } else {
        try {
          _quill.document =
              Document.fromJson(jsonDecode(delta) as List);
        } catch (_) {
          // Corrupt formatting must never blank the words: salvage text.
          final salvaged = StorageService.recoverPlainText(delta);
          if (salvaged == null || salvaged.trim().isEmpty) {
            _quill.document = Document();
          } else {
            _quill.document =
                Document.fromJson(jsonDecode(jsonEncode([
              {'insert': salvaged}
            ])) as List);
          }
        }
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
    _markExistingHashes();
    _wordCount.value =
        countWords(_quill.document.toPlainText());
    _highlighter.call(_applyHighlight);
  }

  Future<void> _newSession() async {
    await _saveNow();
    final folder = _activeFolder();
    final created = await widget.storage.createSession(
        'Untitled ${_sessions.length + 1}',
        folder: folder);
    if (!mounted) return;
    setState(() {
      _sessions = [created, ..._sessions];
      _collapsedFolders.remove(folder);
    });
    await _openSession(created.id);
  }

  List<String> _folderNames() {
    final set = <String>{'Notes', ..._knownFolders};
    for (final s in _sessions) {
      set.add(s.folder);
    }
    final list = set.toList();
    list.sort((a, b) {
      if (a == 'Notes') return -1;
      if (b == 'Notes') return 1;
      return a.compareTo(b);
    });
    return list;
  }

  List<WritingSession> _sessionsIn(String folder) {
    final list =
        _sessions.where((s) => s.folder == folder).toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  Future<void> _moveSession(WritingSession s, String folder) async {
    s.folder = StorageService.normalizeFolder(folder);
    setState(() => _collapsedFolders.remove(s.folder));
    await widget.storage.saveSession(
        s.id, s.title, await _deltaJsonFor(s.id),
        folder: s.folder);
  }

  /// Current saved delta for a session (live doc if it is open).
  Future<String> _deltaJsonFor(String id) async {
    if (id == _activeId) return _deltaJson();
    return await widget.storage.loadSessionDelta(id) ?? '';
  }

  Future<void> _moveDialog(WritingSession s) async {
    final folders = _folderNames();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF4EEDF),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Text('Move "${s.title}" to…',
            style: const TextStyle(
                color: PaperTheme.ink,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: 260,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in folders)
                ListTile(
                  dense: true,
                  title: Text(f,
                      style:
                          const TextStyle(color: PaperTheme.ink)),
                  trailing: f == s.folder
                      ? const Icon(Icons.check,
                          size: 16, color: PaperTheme.ink)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(f),
                ),
            ],
          ),
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
    if (picked == null || !mounted) return;
    await _moveSession(s, picked);
  }

  Future<void> _newFolder() async {
    final name = await _askFolderName(title: 'New folder');
    if (name == null || !mounted) return;
    if (_folderNames()
        .any((f) => f.toLowerCase() == name.toLowerCase())) {
      _notice('A folder called "$name" already exists.');
      return;
    }
    setState(() {
      _knownFolders.add(name);
      _collapsedFolders.remove(name);
    });
    await widget.storage.saveFolders(_knownFolders.toList());
    _notice('Folder "$name" created.');
  }

  Future<void> _renameFolder(String oldName) async {
    final name =
        await _askFolderName(title: 'Rename "$oldName"', initial: oldName);
    if (name == null || !mounted) return;
    if (_folderNames().any((f) =>
        f.toLowerCase() == name.toLowerCase() && f != oldName)) {
      _notice('A folder called "$name" already exists.');
      return;
    }
    for (final s in _sessions) {
      if (s.folder == oldName) {
        s.folder = name;
        await widget.storage.saveSession(
            s.id, s.title, await _deltaJsonFor(s.id),
            folder: name);
      }
    }
    _knownFolders.remove(oldName);
    _knownFolders.add(name);
    await widget.storage.saveFolders(_knownFolders.toList());
    setState(() {
      _collapsedFolders.remove(oldName);
    });
  }

  Future<void> _deleteFolder(String folder) async {
    if (_sessionsIn(folder).isNotEmpty) {
      _notice('Move its notes out first.');
      return;
    }
    setState(() {
      _knownFolders.remove(folder);
      _collapsedFolders.remove(folder);
    });
    await widget.storage.saveFolders(_knownFolders.toList());
    _notice('Folder "$folder" deleted.');
  }

  Future<String?> _askFolderName(
      {required String title, String? initial}) async {
    _folderCtrl.text = initial ?? '';
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
          controller: _folderCtrl,
          autofocus: true,
          onSubmitted: (_) =>
              Navigator.of(ctx).pop(_folderCtrl.text.trim()),
          style:
              const TextStyle(color: PaperTheme.ink, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'e.g. Journal',
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
                Navigator.of(ctx).pop(_folderCtrl.text.trim()),
            child: const Text('Save',
                style: TextStyle(
                    color: PaperTheme.ink,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    // NOTE: _folderCtrl is intentionally NOT disposed here (see field docs).
    if (name == null || name.trim().isEmpty) return null;
    return name.trim();
  }

  Future<void> _deleteSession(String id) async {
    await widget.storage.deleteSession(id);
    if (!mounted) return;
    final remaining =
        _sessions.where((s) => s.id != id).toList();
    final wasActive = _activeId == id;
    // Clear first so the switch below can't re-save (resurrect) the
    // deleted file with the still-loaded text.
    if (wasActive) _activeId = null;
    if (remaining.isEmpty) {
      final created =
          await widget.storage.createSession('First notes');
      setState(() {
        _sessions = [created];
      });
      await _openSession(created.id);
    } else {
      setState(() => _sessions = remaining);
      if (wasActive) await _openSession(remaining.first.id);
    }
  }

  String _deltaJson() {
    try {
      return jsonEncode(_quill.document.toDelta().toJson());
    } catch (_) {
      return '';
    }
  }

  String _activeFolder() {
    for (final s in _sessions) {
      if (s.id == _activeId) return s.folder;
    }
    return 'Notes';
  }

  Future<void> _saveNow() async {
    final id = _activeId;
    if (id == null || !_loaded) return;
    await widget.storage.saveSession(
        id, _titleCtrl.text.trim(), _deltaJson(),
        folder: _activeFolder());
  }

  void _onDocChanged() {
    if (_switching || !_loaded || _activeId == null) return;
    if (_applyingHighlight) return; // our own green paint, not typing
    final id = _activeId!;
    final title = _titleCtrl.text.trim();
    final folder = _activeFolder();
    _saver.call(() => widget.storage
        .saveSession(id, title, _deltaJson(), folder: folder));
    _wordCount.value =
        countWords(_quill.document.toPlainText());
    final onImg = _caretOnImage();
    if (onImg != _onImage) setState(() => _onImage = onImg);
    _updateLookup();
    _highlighter.call(_applyHighlight);
    _scanHashes();
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
      for (final r in current.red) {
        if (!covers(strikeRanges, r.$1, r.$2)) {
          _quill.formatText(
              r.$1, r.$2 - r.$1, const ColorAttribute(null));
        }
      }
      for (final r in strikeRanges) {
        if (!covers(current.strike, r.$1, r.$2)) {
          _quill.formatText(
              r.$1, r.$2 - r.$1, const StrikeThroughAttribute());
        }
        if (!covers(current.red, r.$1, r.$2)) {
          _quill.formatText(
              r.$1, r.$2 - r.$1, const ColorAttribute(_banRedHex));
        }
      }
    } catch (_) {
      // Never interrupt writing for highlight housekeeping.
    } finally {
      _applyingHighlight = false;
    }
  }
  /// Live ranges currently wearing a managed fill / a strike / ban red.
  ({
    List<({int start, int end, String hex})> green,
    List<(int, int)> strike,
    List<(int, int)> red,
  }) _currentMarks(Set<String> managed) {
    final green = <({int start, int end, String hex})>[];
    final strike = <(int, int)>[];
    final red = <(int, int)>[];
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
        final fg = attrs == null ? null : attrs['color'];
        if (fg != null && fg.toString().toLowerCase() == _banRedHex) {
          red.add((pos, pos + len));
        }
        pos += len;
      }
    } catch (_) {}
    return (green: green, strike: strike, red: red);
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
    final folder = _activeFolder();
    _saver.call(() => widget.storage
        .saveSession(id, title, _deltaJson(), folder: folder));
    setState(() {}); // refresh rail titles
  }

  @override
  void dispose() {
    _saveNow();
    _saver.dispose();
    _highlighter.dispose();
    _wordCount.dispose();
    _removeOverlay();
    WidgetsBinding.instance.removeObserver(this);
    _quill.removeListener(_onDocChanged);
    _quill.dispose();
    _titleCtrl.dispose();
    _folderCtrl.dispose();
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

  // ---- Hash tags: #[phrase] bans a phrase on `]`; #word opens a
  // chooser (ban it or put it on the map). Matches already handled this
  // run are skipped so retyping never fires twice.
  static final _phraseTagRe = RegExp(r'#\[([^\]\n]+)\]');

  /// Returns the #fragment (possibly empty) or null when no # tag applies.
  String? _detectHash() {
    final text = _quill.document.toPlainText();
    final sel = _quill.selection;
    if (!sel.isValid || sel.baseOffset < 0) return null;
    final cursor = sel.baseOffset.clamp(0, text.length);
    int i = cursor - 1;
    while (i >= 0 && _isWordChar(text[i])) {
      i--;
    }
    if (i < 0 || text[i] != '#') return null;
    if (i > 0 && !_isBoundary(text[i - 1])) return null;
    return text.substring(i + 1, cursor).toLowerCase();
  }

  void _scanHashes() {
    if (!_loaded || _switching) return;
    String text;
    try {
      text = _quill.document.toPlainText();
    } catch (_) {
      return;
    }
    // #[a whole phrase here] -> banned as one phrase.
    for (final m in _phraseTagRe.allMatches(text)) {
      final full = m.group(0)!;
      if (_handledPhrase.contains(full)) continue;
      _handledPhrase.add(full);
      final phrase = m.group(1)!.trim().toLowerCase();
      if (phrase.isNotEmpty) _banWords([phrase], 'Banned "$phrase".');
    }
  }

  /// Silently mark every #[phrase] already in the text (e.g. just opened
  /// a note) so nothing fires until something new is typed.
  void _markExistingHashes() {
    String text;
    try {
      text = _quill.document.toPlainText();
    } catch (_) {
      return;
    }
    for (final m in _phraseTagRe.allMatches(text)) {
      _handledPhrase.add(m.group(0)!);
    }
  }

  void _banWords(List<String> words, String notice) {
    var changed = false;
    for (final w in words) {
      final k = w.trim().toLowerCase();
      if (k.isNotEmpty && !widget.forbidden.contains(k)) {
        widget.forbidden.add(k);
        changed = true;
      }
    }
    if (!changed) return;
    widget.forbidden.sort();
    widget.storage.saveForbidden(widget.forbidden);
    _highlighter.call(_applyHighlight);
    _notice(notice);
  }

  void _notice(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _updateLookup() {
    if (!_loaded || _activeId == null) return;
    // Never hijack an active text selection with the popup.
    if (_quill.selection.start != _quill.selection.end) {
      _removeOverlay();
      return;
    }
    // @word → mention list from the map.
    final mention = _detectMention();
    if (mention != null) {
      final all = widget.graph.sortedKeys();
      final starts = [
        for (final k in all)
          if (k.startsWith(mention)) k
      ];
      final contains = [
        for (final k in all)
          if (!k.startsWith(mention) && k.contains(mention)) k
      ];
      _popupKind = 'mention';
      _hashFrag = '';
      _frag = mention;
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
      return;
    }
    // #word → chooser: ban it or put it on the map.
    final hash = _detectHash();
    if (hash == null) {
      _removeOverlay();
      return;
    }
    _popupKind = 'hash';
    _hashFrag = hash;
    _matches = const [];
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

  /// Tiny floating popup — mention list or # chooser by mode.
  Widget _buildPicker() {
    if (_popupKind == 'hash') return _buildChooser();
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

  /// #word chooser: ban the typed word or put it on the map.
  Widget _buildChooser() {
    final frag = _hashFrag;
    final ready = frag.isNotEmpty;
    final onMap = widget.graph.get(frag) != null;
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
                      ready ? '"$frag" goes to…' : 'type a word…',
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
            if (ready) ...[
              _chooserRow(
                icon: Icons.block,
                label: onMap ? '"$frag" is on the map' : 'Ban "$frag"',
                enabled: !onMap,
                onTap: () {
                  _banWords([frag], 'Banned "$frag".');
                  _removeOverlay();
                },
              ),
              _chooserRow(
                icon: Icons.account_tree_outlined,
                label: onMap ? 'Open "$frag" on the map' : 'Map "$frag"',
                enabled: true,
                onTap: () {
                  final isNew = widget.graph.get(frag) == null;
                  widget.graph.ensure(frag);
                  widget.storage.saveGraph(widget.graph);
                  widget.onGraphChanged();
                  if (isNew) _notice('"$frag" added to the map.');
                  _removeOverlay();
                  _openMapSheet(frag);
                },
              ),
            ],
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 3, 12, 8),
              child: Text(
                'choose where it goes',
                style: TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 9),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chooserRow({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Container(
          margin:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          padding:
              const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              Icon(icon, size: 14, color: PaperTheme.inkSoft),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: PaperTheme.ink,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
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
                        tooltip: 'New folder',
                        onPressed:
                            _loaded ? _newFolder : null,
                        icon: const Icon(
                            Icons.create_new_folder_outlined,
                            size: 17,
                            color: PaperTheme.inkSoft),
                      ),
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
                      : ListView(
                          children: [
                            for (final folder in _folderNames())
                              _FolderSection(
                                folder: folder,
                                collapsed: _collapsedFolders
                                    .contains(folder),
                                onToggle: () => setState(() {
                                  if (!_collapsedFolders
                                      .remove(folder)) {
                                    _collapsedFolders.add(folder);
                                  }
                                }),
                                onRename: folder == 'Notes'
                                    ? null
                                    : () => _renameFolder(folder),
                                onDelete: folder == 'Notes'
                                    ? null
                                    : () => _deleteFolder(folder),
                                children: [
                                  for (final s
                                      in _sessionsIn(folder))
                                    _NoteRow(
                                      title: s.title,
                                      date: _dateLabel(
                                          s.updatedAt),
                                      active: s.id == _activeId,
                                      onTap: () {
                                        if (s.id != _activeId) {
                                          _openSession(s.id);
                                        }
                                      },
                                      onMove: () =>
                                          _moveDialog(s),
                                      onDelete: () =>
                                          _deleteSession(s.id),
                                    ),
                                ],
                              ),
                          ],
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
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: ValueListenableBuilder<int>(
                                    valueListenable: _wordCount,
                                    builder: (context, n, _) => Text(
                                      '$n ${n == 1 ? 'word' : 'words'}',
                                      style: const TextStyle(
                                          color: PaperTheme.inkSoft,
                                          fontSize: 10.5),
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

/// One folder section in the notes rail.
class _FolderSection extends StatelessWidget {
  final String folder;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final List<Widget> children;

  const _FolderSection({
    required this.folder,
    required this.collapsed,
    required this.onToggle,
    required this.onRename,
    required this.onDelete,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 6),
            child: Row(
              children: [
                Icon(
                    collapsed
                        ? Icons.chevron_right
                        : Icons.expand_more,
                    size: 16,
                    color: PaperTheme.inkSoft),
                Expanded(
                  child: Text(
                    '$folder (${children.length})',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: PaperTheme.inkSoft,
                        fontSize: 11,
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                if (onRename != null)
                  InkWell(
                    onTap: onRename,
                    borderRadius: BorderRadius.circular(8),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.edit_outlined,
                          size: 12, color: PaperTheme.inkSoft),
                    ),
                  ),
                if (onDelete != null)
                  InkWell(
                    onTap: onDelete,
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
        ),
        if (!collapsed) ...children,
        const SizedBox(height: 4),
      ],
    );
  }
}

/// One note row in the rail, with move + delete.
class _NoteRow extends StatelessWidget {
  final String title;
  final String date;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  const _NoteRow({
    required this.title,
    required this.date,
    required this.active,
    required this.onTap,
    required this.onMove,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active ? PaperTheme.chip : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: PaperTheme.ink,
                        fontSize: 13,
                        fontWeight: active
                            ? FontWeight.w600
                            : FontWeight.normal,
                      )),
                  Text(date,
                      style: const TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 10)),
                ],
              ),
            ),
            InkWell(
              onTap: onMove,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.drive_file_move_outlined,
                    size: 13, color: PaperTheme.inkSoft),
              ),
            ),
            InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close,
                    size: 13, color: PaperTheme.inkSoft),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
