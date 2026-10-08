import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        SelectionChangedCause,
        rootBundle;
import 'package:url_launcher/url_launcher.dart';
import 'package:spell_check_on_client/spell_check_on_client.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show
        Attribute,
        BackgroundAttribute,
        BlockEmbed,
        ColorAttribute,
        Document,
        IconButtonData,
        LinkAttribute,
        QuillController,
        QuillEditor,
        QuillEditorConfig,
        QuillIconTheme,
        QuillRawEditorState,
        QuillSimpleToolbar,
        QuillSimpleToolbarConfig,
        StrikeThroughAttribute,
        StyleAttribute,
        getEmbedNode;
import 'package:flutter_quill_extensions/flutter_quill_extensions.dart';

import 'ai_service.dart';
import 'clipboard_image.dart';
import 'computer_video.dart';
import 'computer_video_base.dart';
import 'frame_link.dart';
import 'grammar_check.dart';
import 'graph_model.dart';
import 'image_embed.dart';
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
bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Words typed: letter/digit runs, keeping mid-word apostrophes together.
int countWords(String text) {  return RegExp(r"[\p{L}\p{N}]+(?:'[\p{L}\p{N}]+)?", unicode: true)
      .allMatches(text)
      .length;
}

/// Fill flagging possible typos (offline dictionary).
const String _spellHex = '#ffdfb0';

/// Fill flagging passages a checked grammar structure could fit.
const String _grammarHex = '#d7e5f7';

/// Ranges of likely-misspelled words. Skips the word under [cursor]
/// (still being typed), tokens without letters, and bits of links/tags.
List<(int, int)> findUnknownRanges(
  String text,
  bool Function(String word) isCorrect, {
  int cursor = -1,
}) {
  final out = <(int, int)>[];
  final token =
      RegExp(r"[\p{L}\p{N}]+(?:'[\p{L}\p{N}]+)?", unicode: true);
  final hasLetter = RegExp(r'\p{L}', unicode: true);
  for (final m in token.allMatches(text)) {
    final w = m.group(0)!;
    if (w.length < 2 || !hasLetter.hasMatch(w)) continue;
    if (cursor >= 0 && m.start <= cursor && cursor <= m.end) continue;
    final before = m.start > 0 ? text[m.start - 1] : ' ';
    final after = m.end < text.length ? text[m.end] : ' ';
    if ('.@/#:;'.contains(before) || '.@/#:;'.contains(after)) continue;
    try {
      if (!isCorrect(w)) out.add((m.start, m.end));
    } catch (_) {}
  }
  return out;
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

  /// Offline spell checker (null until the dictionary asset loads).
  SpellCheck? _spell;

  /// Words the user taught the checker via Learn spelling.
  final Set<String> _learned = {};

  /// Live word count of the open note.
  final ValueNotifier<int> _wordCount = ValueNotifier(0);

  /// Distinct flagged words in the open note (for the fix-it sheet).
  final ValueNotifier<List<String>> _spellWords = ValueNotifier(const []);

  /// Already-handled #[phrase] tags this run, so retyping never fires twice.
  final Set<String> _handledPhrase = {};

  // Mention popup state (@frag -> matching words, #frag -> chooser).
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _editorKey = GlobalKey();
  OverlayEntry? _overlay;
  String _popupKind = 'mention'; // 'mention', 'hash' or 'ai'
  List<String> _matches = [];
  String _frag = '';
  String _hashFrag = '';

  // @ai mini-chat (stateless: nothing is ever saved).
  bool _aiOpen = false;
  final TextEditingController _aiQ = TextEditingController();
  final TextEditingController _aiKeyField = TextEditingController();
  GroqClient _aiClient = GroqClient();

  /// Test hook: swap the network client for a fake.
  @visibleForTesting
  void debugSetAiClient(GroqClient client) {
    _aiClient.dispose();
    _aiClient = client;
  }
  String? _aiAnswer;
  String _aiError = '';
  bool _aiBusy = false;
  String? _aiKey; // null = not loaded yet
  bool _editingKey = false;

  // Stream writing: one computer video file per note, floating player.
  // late so widget.storage is available when the player is first opened.
  late final ComputerVideoBase _video =
      ComputerVideo(storage: widget.storage);
  bool _streamOpen = false; // panel expanded
  bool _frameBusy = false; // frame note being captured
  bool _videoOpen = false; // player holds a playable file
  bool _videoMissing = false; // attached ref that would not open
  // Floating player card (dragged around the sheet, never inside it).
  bool _playerHidden = false;
  bool _playerMini = false;
  double _playerRight = 16;
  double _playerBottom = 16;
  Offset _popupOffset = const Offset(0, 40);
  double _editorWidth = 600;

  /// Resolves stored image references for the editor. Built once and
  /// reused: a fresh EmbedBuilder on every rebuild would throw away
  /// Quill's in-progress image resize handles.
  late final QuillEditorImageEmbedConfig _imageEmbedConfig =
      QuillEditorImageEmbedConfig(
    imageProviderBuilder: (context, url) =>
        resolveEmbedImage(widget.storage, url),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _quill = QuillController.basic();
    _focusNode = FocusNode();
    _scrollCtrl = ScrollController();
    _quill.addListener(_onDocChanged);
    _titleCtrl.addListener(_onTitleChanged);
    // The Grammar page and this editor are both alive in an IndexedStack,
    // so flipping the preference there cannot rebuild us. Listen instead.
    _grammarCheckOn = widget.storage.grammarCheckEnabled.value;
    widget.storage.grammarCheckEnabled
        .addListener(_onGrammarCheckPreference);
    listenClipboardImages(_onClipboardImage);
    _boot();
    _initSpell();
  }

  void _onGrammarCheckPreference() {
    final next = widget.storage.grammarCheckEnabled.value;
    if (!mounted || next == _grammarCheckOn) return;
    setState(() => _grammarCheckOn = next);
  }

  /// A pasted screenshot/snippet lands in the note at the caret (the true
  /// video frame, pixel for pixel). Deliberately NOT gated on editor focus:
  /// the snipping overlay steals focus, so requiring it silently eats the
  /// paste — the exact failure it exists to serve. Image files have nowhere
  /// else to go, so an open note always takes them.
  void _onClipboardImage(String dataUrl) {
    if (!mounted || !_loaded || _activeId == null) return;
    try {
      final docLen = _quill.document.length;
      var idx = _quill.selection.isValid
          ? _quill.selection.baseOffset
          : docLen;
      if (idx < 0 || idx > docLen) idx = docLen;
      _quill.document.insert(idx, BlockEmbed.image(dataUrl));
      final at = idx + 1;
      _quill.document.insert(at, '\n');
      _quill.moveCursorToPosition(at + 1);
      _notice('Frame dropped in. Type your note under it.');
    } catch (_) {}
  }

  /// Load the offline dictionary; silently off if the asset is missing.
  /// Wordlist vendored from spell_check_on_client's example assets.
  Future<void> _initSpell() async {
    try {
      final content =
          await rootBundle.loadString('assets/spell/en_words.txt');
      if (!mounted) return;
      setState(() => _spell = SpellCheck.fromWordsContent(
            content,
            letters: LanguageLetters.getLanguageForLanguage('en'),
          ));
      _highlighter.call(_applyHighlight);
    } catch (_) {}
  }

  /// Test hook: inject a tiny dictionary instead of the asset bundle.
  @visibleForTesting
  void debugUseSpell(SpellCheck checker) {
    _spell = checker;
    _highlighter.call(_applyHighlight);
  }

  bool _spellCorrect(String word) {
    final lower = word.toLowerCase();
    if (_learned.contains(lower)) return true;
    final checker = _spell;
    if (checker == null) return true;
    try {
      return checker.isCorrect(word) || checker.isCorrect(lower);
    } catch (_) {
      return true;
    }
  }

  /// Teach the checker a word (Learn spelling), then re-mark the note.
  Future<void> _learnWord(String word,
      [QuillRawEditorState? rawState]) async {
    final k = word.trim().toLowerCase();
    if (k.isEmpty) return;
    setState(() => _learned.add(k));
    await widget.storage.saveLearned(_learned.toList());
    rawState?.hideToolbar();
    _highlighter.call(_applyHighlight);
  }

  /// Replace every occurrence of a typo with the picked suggestion,
  /// keeping an initial capital when the typo had one.
  void _fixTypoEverywhere(String wrong, String right) {
    final w = wrong.trim();
    var r = right.trim();
    if (w.isEmpty || r.isEmpty) return;
    String text;
    try {
      text = _quill.document.toPlainText();
    } catch (_) {
      return;
    }
    final re = RegExp('\\b${RegExp.escape(w)}\\b', caseSensitive: false);
    final ranges = re
        .allMatches(text)
        .map((m) => (m.start, m.end, m.group(0)!))
        .toList();
    if (ranges.isEmpty) return;
    for (var i = ranges.length - 1; i >= 0; i--) {
      final r0 = ranges[i];
      var rep = r;
      final first = r0.$3[0];
      if (first.toUpperCase() == first &&
          first.toLowerCase() != first) {
        rep = r[0].toUpperCase() + r.substring(1);
      }
      try {
        _quill.replaceText(r0.$1, r0.$2 - r0.$1, rep,
            TextSelection.collapsed(offset: r0.$1 + rep.length));
      } catch (_) {}
    }
  }

  Future<void> _boot() async {
    var sessions = await widget.storage.loadSessions();
    final grammarCheckOn =
        await widget.storage.loadGrammarCheckEnabled();
    final storedFolders = await widget.storage.loadFolders();
    _knownFolders.addAll(storedFolders);
    _learned.addAll(await widget.storage.loadLearned());
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
      _grammarCheckOn = grammarCheckOn;
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
      _openVideo(session.videoUrl);
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
      final spellRanges = _spell == null
          ? const <(int, int)>[]
          : findUnknownRanges(
              text, _spellCorrect,
              cursor: _quill.selection.isValid
                  ? _quill.selection.baseOffset
                  : -1);
      final current = _currentMarks({
        ..._managedHexes(widget.graph),
        _spellHex,
      });
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
      final greenPos = [
        for (final r in greenRanges) (r.start, r.end)
      ];
      // Graph words are known words: never flagged as typos.
      final spellWanted = [
        for (final r in spellRanges)
          if (!covers(greenPos, r.$1, r.$2)) r
      ];
      // Publish the distinct typo words for the fix-it sheet.
      final seen = <String>{};
      final typoWords = <String>[];
      for (final r in spellWanted) {
        final w = text.substring(r.$1, r.$2);
        final k = w.toLowerCase();
        if (seen.add(k)) typoWords.add(w);
      }
      if (!_listEquals(typoWords, _spellWords.value)) {
        _spellWords.value = typoWords;
      }
      for (final r in current.spell) {
        if (!covers(spellWanted, r.$1, r.$2)) {
          _quill.formatText(
              r.$1, r.$2 - r.$1, const BackgroundAttribute(null));
        }
      }
      for (final r in spellWanted) {
        if (!covers(current.spell, r.$1, r.$2)) {
          _quill.formatText(
              r.$1, r.$2 - r.$1, const BackgroundAttribute(_spellHex));
        }
      }
    } catch (_) {
      // Never interrupt writing for highlight housekeeping.
    } finally {
      _applyingHighlight = false;
    }
  }
  /// Live ranges currently wearing a managed fill / a strike / ban red /
  /// the spell flag.
  ({
    List<({int start, int end, String hex})> green,
    List<(int, int)> strike,
    List<(int, int)> red,
    List<(int, int)> spell,
  }) _currentMarks(Set<String> managed) {
    final green = <({int start, int end, String hex})>[];
    final strike = <(int, int)>[];
    final red = <(int, int)>[];
    final spell = <(int, int)>[];
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
        if (bg != null &&
            bg.toString().toLowerCase() == _spellHex) {
          spell.add((pos, pos + len));
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
    return (green: green, strike: strike, red: red, spell: spell);
  }

  /// Fix-it sheet: every flagged word with suggestions + Learn.
  void _openSpellSheet() {
    final typos = List<String>.of(_spellWords.value);
    if (typos.isEmpty) return;
    final Map<String, List<String>> suggestions = {};
    for (final w in typos) {
      try {
        suggestions[w] =
            _spell?.didYouMeanAny(w, maxWords: 4).take(3).toList() ?? [];
      } catch (_) {
        suggestions[w] = [];
      }
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: PaperTheme.paper,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        padding:
            const EdgeInsets.fromLTRB(18, 10, 18, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: PaperTheme.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Possible typos — tap a fix',
              style: TextStyle(
                  color: PaperTheme.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final w in typos)
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 5),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  w,
                                  style: const TextStyle(
                                      color: PaperTheme.ink,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                              InkWell(
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  _learnWord(w);
                                },
                                borderRadius:
                                    BorderRadius.circular(10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color:
                                            PaperTheme.lineThin),
                                    borderRadius:
                                        BorderRadius.circular(10),
                                  ),
                                  child: const Text('Learn',
                                      style: TextStyle(
                                          color:
                                              PaperTheme.inkSoft,
                                          fontSize: 11)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final s
                                  in suggestions[w] ?? const <String>[])
                                InkWell(
                                  onTap: () {
                                    Navigator.of(ctx).pop();
                                    _fixTypoEverywhere(w, s);
                                  },
                                  borderRadius:
                                      BorderRadius.circular(12),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: PaperTheme.surface,
                                      border: Border.all(
                                          color: PaperTheme.lineThin),
                                      borderRadius:
                                          BorderRadius.circular(12),
                                    ),
                                    child: Text(s,
                                        style: const TextStyle(
                                            color: PaperTheme.ink,
                                            fontSize: 12.5)),
                                  ),
                                ),
                              if ((suggestions[w] ?? const []).isEmpty)
                                const Text(
                                  'no close match found',
                                  style: TextStyle(
                                      color: PaperTheme.inkSoft,
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Right-click menu: spelling suggestions + Learn when on a typo,
  /// then the standard Cut / Copy / Paste / Select All.
  Widget _spellMenu(BuildContext context, QuillRawEditorState rawState) {
    String word = '';
    int start = -1;
    int end = -1;
    try {
      final text = _quill.document.toPlainText();
      final sel = _quill.selection;
      final cursor = sel.baseOffset.clamp(0, text.length);
      if (sel.start != sel.end) {
        final picked =
            text.substring(sel.start.clamp(0, text.length), cursor).trim();
        if (!picked.contains(RegExp(r'\s'))) {
          word = picked;
          start = sel.start;
          end = cursor;
        }
      } else {
        final m = RegExp(r"[\p{L}\p{N}]+(?:'[\p{L}\p{N}]+)?",
                unicode: true)
            .allMatches(text)
            .where((e) => e.start <= cursor && cursor <= e.end);
        if (m.isNotEmpty) {
          word = m.first.group(0)!;
          start = m.first.start;
          end = m.first.end;
        }
      }
    } catch (_) {}
    final misspelled = word.length >= 2 && !_spellCorrect(word);
    List<String> suggestions = const [];
    if (misspelled && _spell != null) {
      try {
        suggestions =
            _spell!.didYouMeanAny(word, maxWords: 4).take(4).toList();
      } catch (_) {}
    }
    final collapsed =
        _quill.selection.start == _quill.selection.end;

    Widget row({
      required IconData icon,
      required String label,
      required bool enabled,
      required VoidCallback onTap,
    }) {
      return InkWell(
        onTap: enabled
            ? () {
                rawState.hideToolbar();
                onTap();
              }
            : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: PaperTheme.inkSoft),
                const SizedBox(width: 10),
                Text(label,
                    style: const TextStyle(
                        color: PaperTheme.ink, fontSize: 13)),
              ],
            ),
          ),
        ),
      );
    }

    void replaceWith(String replacement) {
      if (start < 0 || end <= start) return;
      _quill.replaceText(
          start,
          end - start,
          replacement,
          TextSelection.collapsed(
              offset: start + replacement.length));
    }

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 230,
        decoration: BoxDecoration(
          color: const Color(0xFFF4EEDF),
          border: Border.all(color: PaperTheme.lineThin),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3E3A31).withValues(alpha: 0.16),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in suggestions)
              row(
                icon: Icons.spellcheck,
                label: s,
                enabled: true,
                onTap: () => replaceWith(s),
              ),
            if (misspelled)
              row(
                icon: Icons.school_outlined,
                label: 'Learn spelling',
                enabled: true,
                onTap: () => _learnWord(word, rawState),
              ),
            if (misspelled || suggestions.isNotEmpty)
              const Divider(height: 1, color: PaperTheme.lineThin),
            row(
              icon: Icons.content_cut,
              label: 'Cut',
              enabled: !collapsed,
              onTap: () => rawState
                  .cutSelection(SelectionChangedCause.keyboard),
            ),
            row(
              icon: Icons.copy,
              label: 'Copy',
              enabled: !collapsed,
              onTap: () => rawState
                  .copySelection(SelectionChangedCause.keyboard),
            ),
            row(
              icon: Icons.paste,
              label: 'Paste',
              enabled: true,
              onTap: () async =>
                  rawState.pasteText(SelectionChangedCause.keyboard),
            ),
            row(
              icon: Icons.select_all,
              label: 'Select All',
              enabled: true,
              onTap: () => rawState
                  .selectAll(SelectionChangedCause.keyboard),
            ),
          ],
        ),
      ),
    );
  }
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

  // ---- Stream writing: one YouTube link per note + frame notes ----

  WritingSession? _activeSession() {
    final id = _activeId;
    if (id == null) return null;
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Open this note's computer video (or park the player when none).
  /// Fire-and-forget on purpose: the open touches real disk IO, which
  /// must never be awaited on the UI path. Stale runs (rapid switches)
  /// must not resurrect old players, hence the generation guard.
  int _videoGen = 0;

  void _openVideo(String ref) {
    final gen = ++_videoGen;
    final want = _activeId;
    _video.close();
    setState(() {
      _videoOpen = false;
      _videoMissing = false;
      _playerHidden = false;
      _playerMini = false;
    });
    if (ref.trim().isEmpty) return;
    _video.openRef(ref).then((ok) {
      if (!mounted || gen != _videoGen || _activeId != want) {
        if (!ok) _video.close();
        return;
      }
      if (!ok) {
        final why = _video.lastError;
        if (why.isNotEmpty) _notice('Video would not open: $why');
      }
      setState(() {
        _videoOpen = ok;
        _videoMissing = !ok;
      });
    });
  }

  /// Test hook: pretend a file was attached (no native picker in tests).
  @visibleForTesting
  void debugAttachVideo(String ref) {
    final session = _activeSession();
    if (session == null) return;
    session.videoUrl = ref;
    _openVideo(ref);
  }

  /// Test hook: force the player UI state (the real open awaits disk IO,
  /// which the widget sandbox cannot complete).
  @visibleForTesting
  void debugSetVideoState({required bool open, required bool missing}) {
    setState(() {
      _videoOpen = open;
      _videoMissing = missing;
    });
  }

  Future<void> _chooseVideo() async {
    final session = _activeSession();
    if (session == null) return;
    PickedVideo? picked;
    try {
      picked = await _video.pick();
    } catch (_) {}
    if (picked == null) return; // cancelled
    final ref = _video.store(picked);
    session.videoUrl = ref;
    setState(() => _streamOpen = true);
    _openVideo(ref);
    if (!mounted) return;
    await widget.storage.saveSession(
        session.id, _titleCtrl.text.trim(), _deltaJson(),
        folder: session.folder, video: ref);
    if (mounted) setState(() {});
    _notice('Video attached: ${FrameLink.basename(ref)}. Pause it '
        'anytime, then frame note grabs that exact moment.');
  }

  Future<void> _removeVideo() async {
    final session = _activeSession();
    if (session == null) return;
    session.videoUrl = '';
    _video.close();
    await widget.storage.saveSession(
        session.id, _titleCtrl.text.trim(), _deltaJson(),
        folder: session.folder, video: '');
    if (mounted) {
      setState(() {
        _videoOpen = false;
        _videoMissing = false;
      });
    }
  }

  /// Freeze the paused moment into the note: the exact frame, a timestamp
  /// label linked to that second, and a blank line to type under.
  Future<void> _takeFrameNote() async {
    final session = _activeSession();
    final ref = (session?.videoUrl ?? '').trim();
    if (ref.isEmpty || _frameBusy || !_videoOpen) {
      if (ref.isNotEmpty && !_videoOpen && mounted) {
        _notice(_videoMissing
            ? 'Video file not found — choose it again.'
            : 'Video is still loading. Give it a moment.');
      }
      return;
    }
    setState(() => _frameBusy = true);
    try {
      final seconds = _video.currentSeconds();
      String? shot;
      try {
        shot = await _video.captureFrame();
      } catch (_) {}
      _insertFrameNote(seconds, imageUrl: shot);
      _focusNode.requestFocus();
      _notice(shot != null
          ? 'Frame captured.'
          : 'Moment marked. On this device add the picture with a snip + paste.');
    } finally {
      if (mounted) setState(() => _frameBusy = false);
    }
  }

  void _insertFrameNote(int seconds, {String? imageUrl}) {
    try {
      final label = '⏱ ${FrameLink.formatTime(seconds)}';
      final url = FrameLink.at(seconds);
      final docLen = _quill.document.length;
      var idx = _quill.selection.isValid
          ? _quill.selection.baseOffset
          : docLen;
      if (idx < 0 || idx > docLen) idx = docLen;
      var at = idx;
      if (imageUrl != null) {
        _quill.document.insert(at, BlockEmbed.image(imageUrl));
        at += 1;
      }
      _quill.document.insert(at, '\n$label ');
      _quill.formatText(at + 1, label.length, LinkAttribute(url));
      at += 1 + label.length + 1;
      _quill.document.insert(at, '\n');
      _quill.moveCursorToPosition(at + 1);
    } catch (_) {
      _notice('Could not drop the frame note here.');
    }
  }

  /// Frame-note labels seek this note's player; legacy YouTube labels and
  /// every other link open outside the app.
  Future<void> _onEditorLink(String url) async {
    try {
      final fs = FrameLink.secondsOf(url);
      if (fs != null && _videoOpen) {
        setState(() {
          _streamOpen = true;
          _playerHidden = false;
        });
        await _video.seekTo(fs);
        return;
      }
      await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
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
    widget.storage.grammarCheckEnabled
        .removeListener(_onGrammarCheckPreference);
    _saver.dispose();
    _highlighter.dispose();
    _wordCount.dispose();
    _aiQ.dispose();
    _aiKeyField.dispose();
    _aiClient.dispose();
    _video.close();
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

  /// Grammar check state.
  bool _grammarBusy = false;

  /// User preference: when off the "grammar check" chip is not offered.
  bool _grammarCheckOn = true;

  /// Resolved grammar flags from the last check (quote + sentence).
  List<({String quote, String sentence, String category, int start})>
      _grammarFlags = [];

  /// Run the AI grammar check against the checked reference sentences.
  /// Marks matching passages blue and lists which structure each fits.
  /// Never rewrites or suggests rephrasings.
  Future<void> _runGrammarCheck() async {
    if (_grammarBusy || !_loaded) return;
    if (!_grammarCheckOn) {
      _notice('Grammar check is off — turn it back on from the '
          'Grammar page.');
      return;
    }
    List<GrammarItem> checked = [];
    try {
      final all = await widget.storage.loadGrammar();
      checked = [for (final g in all) if (g.checked) g];
    } catch (_) {}
    if (!mounted) return;
    if (checked.isEmpty) {
      _notice('Check some sentences on the Grammar page first.');
      return;
    }
    String text;
    try {
      text = _quill.document.toPlainText();
    } catch (_) {
      return;
    }
    if (text.trim().isEmpty) {
      _notice('Write something first.');
      return;
    }
    final key = await widget.storage.loadAiKey();
    if (!mounted) return;
    if (key.isEmpty) {
      _notice('Add your Groq key via @ai first.');
      return;
    }
    setState(() => _grammarBusy = true);
    try {
      final prompt = buildGrammarPrompt(text, checked);
      final answer = await _aiClient.ask(key, prompt);
      if (!mounted) return;
      final flags = parseGrammarFlags(answer);
      final resolved = <({String quote, String sentence, String category, int start})>[];
      for (final f in flags) {
        final ref = resolveGrammarFlag(f, checked);
        if (ref == null) continue;
        final at = text.indexOf(f.quote);
        if (at < 0) continue;
        resolved.add((
          quote: f.quote,
          sentence: ref.sentence,
          category: ref.category,
          start: at,
        ));
      }
      // Paint the found passages; lift only our previous grammar paint.
      _applyingHighlight = true;
      try {
        final current = _currentMarks({
          ..._managedHexes(widget.graph),
          _spellHex,
          _grammarHex,
        });
        bool covers(List<(int, int)> list, int s, int e) {
          for (final r in list) {
            if (r.$1 <= s && r.$2 >= e) return true;
          }
          return false;
        }

        final wanted = [
          for (final r in resolved) (r.start, r.start + r.quote.length)
        ];
        for (final r in current.green) {
          if (r.hex == _grammarHex && !covers(wanted, r.start, r.end)) {
            _quill.formatText(
                r.start, r.end - r.start, const BackgroundAttribute(null));
          }
        }
        for (final r in wanted) {
          if (!covers(
              [for (final g in current.green) (g.start, g.end)],
              r.$1,
              r.$2)) {
            _quill.formatText(r.$1, r.$2 - r.$1,
                const BackgroundAttribute(_grammarHex));
          }
        }
      } catch (_) {
      } finally {
        _applyingHighlight = false;
      }
      setState(() {
        _grammarBusy = false;
        _grammarFlags = resolved;
      });
      _showGrammarResults(answer);
    } catch (e) {
      if (!mounted) return;
      setState(() => _grammarBusy = false);
      _notice(e.toString());
    }
  }

  void _showGrammarResults(String rawAnswer) {
    final flags = List.of(_grammarFlags);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: PaperTheme.paper,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        padding:
            const EdgeInsets.fromLTRB(18, 10, 18, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: PaperTheme.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              flags.isEmpty
                  ? 'No matching passages found'
                  : '${flags.length} ${flags.length == 1 ? 'passage' : 'passages'} to look at',
              style: const TextStyle(
                  color: PaperTheme.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Only the matching structure is named — nothing rewritten.',
              style: TextStyle(
                  color: PaperTheme.inkSoft, fontSize: 11),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: flags.isEmpty
                  ? SingleChildScrollView(
                      child: Text(
                        rawAnswer.length > 1200
                            ? rawAnswer.substring(0, 1200)
                            : rawAnswer,
                        style: const TextStyle(
                            color: PaperTheme.inkSoft,
                            fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: flags.length,
                      itemBuilder: (context, i) {
                        final f = flags[i];
                        return InkWell(
                          onTap: () {
                            Navigator.of(ctx).pop();
                            try {
                              _quill.moveCursorToPosition(f.start);
                            } catch (_) {}
                            _focusNode.requestFocus();
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                                vertical: 4),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFE8D6),
                              border: Border.all(
                                  color: PaperTheme.lineThin),
                              borderRadius:
                                  BorderRadius.circular(10),
                            ),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '“…${f.quote}…”',
                                  style: const TextStyle(
                                      color: PaperTheme.ink,
                                      fontSize: 13,
                                      fontStyle:
                                          FontStyle.italic),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'fits: [${f.category}] ${f.sentence}',
                                  style: const TextStyle(
                                      color: PaperTheme.inkSoft,
                                      fontSize: 11),
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
    );
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
    if (_aiOpen) {
      _overlay?.markNeedsBuild();
      return;
    }
    // Never hijack an active text selection with the popup.
    if (_quill.selection.start != _quill.selection.end) {
      _removeOverlay();
      return;
    }
    // @ai -> mini-chat instead of the word list.
    final mention = _detectMention();
    if (mention != null) {
      if (mention == 'ai') {
        _openAiChat();
        return;
      }
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
              onTap: _dismissPopup,
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

  /// User-visible dismiss (barrier tap, × buttons): also closes chat mode
  /// so a later @ai starts fresh. Plain _removeOverlay keeps _aiOpen so
  /// _showOverlay can replace the entry while opening.
  void _dismissPopup() {
    _aiOpen = false;
    _removeOverlay();
  }

  /// @ai typed: consume the token like a slash command and open the
  /// mini-chat. Nothing about the chat is saved anywhere.
  void _openAiChat() {
    try {
      final text = _quill.document.toPlainText();
      final cursor =
          _quill.selection.baseOffset.clamp(0, text.length);
      int i = cursor - 1;
      while (i >= 0 && _isWordChar(text[i])) {
        i--;
      }
      if (i >= 0 && text.substring(i, cursor).toLowerCase() == '@ai') {
        _quill.replaceText(i, cursor - i, '',
            TextSelection.collapsed(offset: i));
      }
    } catch (_) {}
    _aiOpen = true;
    _popupKind = 'ai';
    _aiAnswer = null;
    _aiError = '';
    _aiBusy = false;
    _aiQ.clear();
    _aiKey = null;
    _editingKey = false;
    _estimateCaretOffset();
    if (_overlay == null) {
      _showOverlay();
    } else {
      _overlay!.markNeedsBuild();
    }
    _loadAiKey();
  }

  Future<void> _loadAiKey() async {
    final k = await widget.storage.loadAiKey();
    if (!mounted || !_aiOpen) return;
    _aiKey = k;
    _refreshAiCard();
  }

  /// The popup lives in its own overlay tree: SheetView setState alone
  /// never repaints it, so every AI state change refreshes it explicitly.
  void _refreshAiCard() {
    if (mounted) setState(() {});
    _overlay?.markNeedsBuild();
  }

  Future<void> _saveAiKeyField() async {
    final key = _aiKeyField.text.trim();
    if (key.isEmpty) return;
    await widget.storage.saveAiKey(key);
    if (!mounted) return;
    _aiKey = key;
    _editingKey = false;
    _aiError = '';
    _refreshAiCard();
  }

  Future<void> _askAi() async {
    final key = _aiKey ?? await widget.storage.loadAiKey();
    if (!mounted || !_aiOpen) return;
    _aiKey = key;
    _aiError = '';
    _refreshAiCard();
    if (key.isEmpty) {
      _aiError = 'Paste your Groq API key first.';
      _refreshAiCard();
      return;
    }
    final q = _aiQ.text.trim();
    if (q.isEmpty) return;
    _aiBusy = true;
    _aiError = '';
    _aiAnswer = null;
    _refreshAiCard();
    try {
      final answer = await _aiClient.ask(key, q);
      if (!mounted || !_aiOpen) return;
      _aiAnswer = answer;
      _aiBusy = false;
      _refreshAiCard();
    } catch (e) {
      if (!mounted || !_aiOpen) return;
      final msg = e.toString();
      _aiError = msg;
      _aiBusy = false;
      if (msg.contains('401')) _editingKey = true;
      _refreshAiCard();
    }
  }

  /// Tiny floating popup — mention list, # chooser or mini-chat by mode.
  Widget _buildPicker() {
    if (_popupKind == 'ai') return _buildAiCard();
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
                    onTap: _dismissPopup,
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
  /// This note's computer video in the floating card, or a missing-file
  /// card when the attached file cannot be opened anymore.
  Widget _buildPlayer() {
    if (!_videoOpen) {
      if (!_videoMissing) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: PaperTheme.lineThin),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie_outlined,
                size: 26, color: PaperTheme.inkSoft),
            const SizedBox(height: 6),
            Text(
              '${FrameLink.basename(_activeSession()?.videoUrl ?? '')} not found',
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              style: const TextStyle(
                  color: PaperTheme.inkSoft, fontSize: 11),
            ),
            TextButton(
              onPressed: _chooseVideo,
              child: const Text('choose file',
                  style: TextStyle(
                      color: PaperTheme.ink, fontSize: 12)),
            ),
          ],
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: _video.buildPlayer(),
      ),
    );
  }

  /// The note's video as a draggable card floating OVER the sheet, so
  /// the note keeps its full height no matter the video size. Drag the
  /// header to move it; frame/collapse/hide live in the header too.
  Widget _buildFloatingCard(double maxWidth) {
    final w = (maxWidth - 48).clamp(220.0, 380.0);
    return Container(
      width: w,
      decoration: BoxDecoration(
        color: const Color(0xFFF4EEDF),
        border: Border.all(color: PaperTheme.lineThin),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color:
                const Color(0xFF3E3A31).withValues(alpha: 0.22),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onPanUpdate: (d) => setState(() {
              _playerRight =
                  (_playerRight - d.delta.dx).clamp(0.0, 3000.0);
              _playerBottom =
                  (_playerBottom - d.delta.dy).clamp(0.0, 3000.0);
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 4),
              decoration: const BoxDecoration(
                border: Border(
                    bottom:
                        BorderSide(color: PaperTheme.lineThin)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.drag_indicator,
                      size: 14, color: PaperTheme.inkSoft),
                  Expanded(
                    child: Text(
                        FrameLink.basename(
                            _activeSession()?.videoUrl ?? ''),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: PaperTheme.inkSoft,
                            fontSize: 11)),
                  ),
                  InkWell(
                    onTap: _frameBusy ? null : _takeFrameNote,
                    borderRadius: BorderRadius.circular(10),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.photo_camera_outlined,
                          size: 15, color: PaperTheme.ink),
                    ),
                  ),
                  InkWell(
                    onTap: () => setState(
                        () => _playerMini = !_playerMini),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                          _playerMini
                              ? Icons.expand_more
                              : Icons.expand_less,
                          size: 15,
                          color: PaperTheme.inkSoft),
                    ),
                  ),
                  InkWell(
                    onTap: () =>
                        setState(() => _playerHidden = true),
                    borderRadius: BorderRadius.circular(10),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close,
                          size: 14,
                          color: PaperTheme.inkSoft),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!_playerMini)
            Padding(
              padding: const EdgeInsets.all(8),
              child: _buildPlayer(),
            ),
        ],
      ),
    );
  }

  /// Collapsible stream-video section: link field, player, frame notes.
  Widget _buildStreamPanel() {
    final attached =
        (_activeSession()?.videoUrl ?? '').trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: PaperTheme.surface,
        border: Border.all(color: PaperTheme.lineThin),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () =>
                setState(() => _streamOpen = !_streamOpen),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  const Icon(Icons.movie_outlined,
                      size: 15, color: PaperTheme.ink),
                  const SizedBox(width: 6),
                  const Text('stream video',
                      style: TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 11.5)),
                  if (attached) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                          color: Color(0xFF2E7D32),
                          shape: BoxShape.circle),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                      _streamOpen
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 16,
                      color: PaperTheme.inkSoft),
                ],
              ),
            ),
          ),
          if (_streamOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      TextButton(
                        onPressed: _chooseVideo,
                        child: Text(
                            attached ? 'Change file…' : 'Choose file…',
                            style: const TextStyle(
                                color: PaperTheme.ink,
                                fontSize: 12)),
                      ),
                      Expanded(
                        child: Text(
                          attached
                              ? FrameLink.basename(
                                  _activeSession()?.videoUrl ?? '')
                              : 'no video attached',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: PaperTheme.inkSoft,
                              fontSize: 12),
                        ),
                      ),
                      if (attached)
                        TextButton(
                          onPressed: _removeVideo,
                          child: const Text('Remove',
                              style: TextStyle(
                                  color: PaperTheme.inkSoft,
                                  fontSize: 12)),
                        ),
                    ],
                  ),
                  if (attached) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        InkWell(
                          onTap:
                              _frameBusy ? null : _takeFrameNote,
                          borderRadius:
                              BorderRadius.circular(14),
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6),
                            decoration: BoxDecoration(
                              color: PaperTheme.surface,
                              border: Border.all(
                                  color: PaperTheme.lineThin),
                              borderRadius:
                                  BorderRadius.circular(14),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_frameBusy)
                                  const SizedBox(
                                    width: 11,
                                    height: 11,
                                    child:
                                        CircularProgressIndicator(
                                            strokeWidth: 2),
                                  )
                                else
                                  const Icon(
                                      Icons
                                          .photo_camera_outlined,
                                      size: 14,
                                      color: PaperTheme.ink),
                                const SizedBox(width: 4),
                                Text(
                                    _frameBusy
                                        ? 'framing…'
                                        : 'frame note',
                                    style: const TextStyle(
                                        color:
                                            PaperTheme.inkSoft,
                                        fontSize: 10.5)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            kIsWeb
                                ? 'pause, then frame note grabs the exact moment'
                                : 'pause, then frame note marks the moment',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: PaperTheme.inkSoft,
                                fontSize: 10.5),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(
                            Icons
                                .picture_in_picture_alt_outlined,
                            size: 13,
                            color: PaperTheme.inkSoft),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            'the video floats over the sheet — drag it anywhere',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: PaperTheme.inkSoft,
                                fontSize: 10.5),
                          ),
                        ),
                        if (_playerHidden)
                          TextButton(
                            onPressed: () => setState(
                                () => _playerHidden = false),
                            child: const Text('show player',
                                style: TextStyle(
                                    color: PaperTheme.ink,
                                    fontSize: 12)),
                          )
                        else
                          TextButton(
                            onPressed: () => setState(
                                () => _playerHidden = true),
                            child: const Text('hide',
                                style: TextStyle(
                                    color: PaperTheme.inkSoft,
                                    fontSize: 12)),
                          ),
                      ],
                    ),
                    // (screen-share live capture retired with YouTube.)
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAiCard() {
    final hasKey = (_aiKey ?? '').isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 300,
        constraints: const BoxConstraints(maxHeight: 380),
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
                  const Expanded(
                    child: Text(
                      'Ask Groq',
                      style: TextStyle(
                        color: PaperTheme.inkSoft,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: _dismissPopup,
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close,
                          size: 14, color: PaperTheme.inkSoft),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!hasKey || _editingKey) ...[
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Paste your Groq API key. It stays on this device.',
                              style: TextStyle(
                                  color: PaperTheme.inkSoft,
                                  fontSize: 11),
                            ),
                          ),
                          InkWell(
                            onTap: () => launchUrl(
                                Uri.parse(
                                    'https://console.groq.com/keys'),
                                mode: LaunchMode
                                    .externalApplication),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Text('get one',
                                  style: TextStyle(
                                      color:
                                          PaperTheme.inkSoft,
                                      fontSize: 10,
                                      decoration: TextDecoration
                                          .underline)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _aiKeyField,
                        obscureText: true,
                        onSubmitted: (_) => _saveAiKeyField(),
                        style: const TextStyle(
                            color: PaperTheme.ink, fontSize: 12),
                        decoration: InputDecoration(
                          hintText: 'groq key…',
                          hintStyle: const TextStyle(
                              color: PaperTheme.inkSoft,
                              fontSize: 11),
                          filled: true,
                          fillColor: PaperTheme.surface,
                          contentPadding:
                              const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(10),
                            borderSide: const BorderSide(
                                color: PaperTheme.lineThin),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(10),
                            borderSide: const BorderSide(
                                color: PaperTheme.lineThin),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed:
                              _aiBusy ? null : _saveAiKeyField,
                          child: const Text('Save key',
                              style: TextStyle(
                                  color: PaperTheme.ink,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ] else ...[
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Key saved on this device.',
                              style: TextStyle(
                                  color: PaperTheme.inkSoft,
                                  fontSize: 10),
                            ),
                          ),
                          InkWell(
                            onTap: () {
                              _editingKey = true;
                              _aiKeyField.clear();
                              _refreshAiCard();
                            },
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Text('change',
                                  style: TextStyle(
                                      color:
                                          PaperTheme.inkSoft,
                                      fontSize: 10,
                                      decoration: TextDecoration
                                          .underline)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _aiQ,
                        maxLines: 3,
                        minLines: 1,
                        onSubmitted: (_) => _askAi(),
                        style: const TextStyle(
                            color: PaperTheme.ink, fontSize: 12.5),
                        decoration: InputDecoration(
                          hintText:
                              'e.g. what better word than happy can i use?',
                          hintStyle: const TextStyle(
                              color: PaperTheme.inkSoft,
                              fontSize: 11),
                          filled: true,
                          fillColor: PaperTheme.surface,
                          contentPadding:
                              const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(10),
                            borderSide: const BorderSide(
                                color: PaperTheme.lineThin),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(10),
                            borderSide: const BorderSide(
                                color: PaperTheme.lineThin),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _aiBusy ? null : _askAi,
                          icon: _aiBusy
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child:
                                      CircularProgressIndicator(
                                          strokeWidth: 2),
                                )
                              : const Icon(Icons.send,
                                  size: 14,
                                  color: PaperTheme.ink),
                          label: Text(
                              _aiBusy ? 'thinking…' : 'Ask',
                              style: const TextStyle(
                                  color: PaperTheme.ink,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                    if (_aiError.isNotEmpty)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 6),
                        child: Text(
                          _aiError,
                          style: const TextStyle(
                              color: Color(0xFF8F2F25),
                              fontSize: 11),
                        ),
                      ),
                    if (_aiAnswer != null) ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: PaperTheme.surface,
                          border: Border.all(
                              color: PaperTheme.lineThin),
                          borderRadius:
                              BorderRadius.circular(10),
                        ),
                        child: SelectableText(
                          _aiAnswer!,
                          style: const TextStyle(
                              color: PaperTheme.ink,
                              fontSize: 12.5,
                              height: 1.45),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(
                                text: _aiAnswer!));
                            _notice('Answer copied.');
                          },
                          icon: const Icon(Icons.copy,
                              size: 13,
                              color: PaperTheme.inkSoft),
                          label: const Text('Copy',
                              style: TextStyle(
                                  color: PaperTheme.inkSoft,
                                  fontSize: 11)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                'answers are not saved',
                style: TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 9),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
                    onTap: _dismissPopup,
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
          // Editor side, with the stream video floating over it.
          Expanded(
            child: LayoutBuilder(
              builder: (context, cons) => Stack(
                children: [
                  Positioned.fill(
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
                                  if (_grammarCheckOn) ...[
                                    const SizedBox(width: 8),
                                    InkWell(
                                      onTap: _grammarBusy
                                          ? null
                                          : _runGrammarCheck,
                                    borderRadius:
                                        BorderRadius.circular(14),
                                    child: Container(
                                      padding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 5),
                                      decoration: BoxDecoration(
                                        color: PaperTheme.surface,
                                        border: Border.all(
                                            color:
                                                PaperTheme.lineThin),
                                        borderRadius:
                                            BorderRadius.circular(14),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (_grammarBusy)
                                            const SizedBox(
                                              width: 11,
                                              height: 11,
                                              child:
                                                  CircularProgressIndicator(
                                                      strokeWidth: 2),
                                            )
                                          else
                                            const Icon(
                                                Icons.spellcheck,
                                                size: 14,
                                                color:
                                                    PaperTheme.ink),
                                          const SizedBox(width: 4),
                                          Text(
                                              _grammarBusy
                                                  ? 'checking…'
                                                  : 'grammar check',
                                              style: const TextStyle(
                                                  color: PaperTheme
                                                      .inkSoft,
                                                  fontSize: 10.5)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
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
                              // Stream writing: this note's video + frame notes.
                              _buildStreamPanel(),
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
                                        contextMenuBuilder: _spellMenu,
                                        onLaunchUrl: _onEditorLink,
                                        embedBuilders: kIsWeb
                                            ? FlutterQuillEmbeds
                                                .editorWebBuilders(
                                              imageEmbedConfig:
                                                  _imageEmbedConfig,
                                            )
                                            : FlutterQuillEmbeds
                                                .editorBuilders(
                                              imageEmbedConfig:
                                                  _imageEmbedConfig,
                                            ),
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
                                child: Row(
                                  children: [
                                    ValueListenableBuilder<List<String>>(
                                      valueListenable: _spellWords,
                                      builder: (context, typos, _) {
                                        if (typos.isEmpty) {
                                          return const SizedBox.shrink();
                                        }
                                        return InkWell(
                                          onTap: _openSpellSheet,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          child: Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 9,
                                                    vertical: 4),
                                            decoration: BoxDecoration(
                                              color: const Color(
                                                  0xFFFFDFB0),
                                              border: Border.all(
                                                  color: PaperTheme
                                                      .lineThin),
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      12),
                                            ),
                                            child: Row(
                                              mainAxisSize:
                                                  MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                    Icons.spellcheck,
                                                    size: 13,
                                                    color:
                                                        PaperTheme.ink),
                                                const SizedBox(width: 4),
                                                Text(
                                                  '${typos.length} to fix',
                                                  style: const TextStyle(
                                                      color:
                                                          PaperTheme
                                                              .ink,
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight
                                                              .w600),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                    const Spacer(),
                                    Align(
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
                                  ],
                                ),
                              ),
                              // Clearance so the floating nav pill never
                              // covers the fixed footer (card space, not a gap).
                              const SizedBox(height: 64),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                    if ((_activeSession()?.videoUrl ?? '')
                            .trim()
                            .isNotEmpty &&
                        !_playerHidden)
                      Positioned(
                        right: _playerRight,
                        bottom: _playerBottom,
                        child:
                            _buildFloatingCard(cons.maxWidth),
                      ),
                  ],
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
