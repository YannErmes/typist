import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'frame_link.dart';
import 'graph_model.dart';

/// One titled writing session (a document).
class WritingSession {
  final String id;
  String title;
  String folder;
  int updatedAt;

  /// Attached stream-writing video (YouTube link), or '' for none.
  String videoUrl;
  WritingSession(this.id, this.title, this.updatedAt,
      {this.folder = 'Notes', this.videoUrl = ''});
}

/// One reference sentence on the grammar page.
class GrammarItem {
  final String id;
  String text;
  String category;
  bool checked;
  GrammarItem({
    required this.id,
    required this.text,
    this.category = 'General',
    this.checked = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'category': category,
        'checked': checked,
      };

  static GrammarItem? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final text = (raw['text'] ?? '').toString().trim();
    if (text.isEmpty) return null;
    final category =
        (raw['category'] ?? 'General').toString().trim();
    return GrammarItem(
      id: (raw['id'] ?? '').toString().isEmpty
          ? '${DateTime.now().millisecondsSinceEpoch}'
          : (raw['id']).toString(),
      text: text,
      category: category.isEmpty ? 'General' : category,
      checked: raw['checked'] != false,
    );
  }
}

/// All persistence is local files, written silently with dart:io.
/// Layout: [Documents]/WordGraphTool/`sheets/<id>.json` (titled sessions
/// with Quill delta content) + words per-word .md files.
/// A stored video reference, minus leftovers from the retired YouTube
/// flow (those links are unplayable by the local file player).
String _cleanVideo(String? raw) {
  final v = (raw ?? '').trim();
  return FrameLink.isLegacyLink(v) ? '' : v;
}
/// Layout: [Documents]/WordGraphTool/`sheets/<id>.json` (titled sessions
/// with Quill delta content) + words per-word .md files.
class StorageService {
  Directory? _base;
  Directory? _wordsDir;
  Directory? _sheetsDir;
  Directory? _imagesDir;
  File? _legacySheetFile;
  File? _forbiddenFile;

  Directory? get baseDir => _base;
  String get basePath => _base?.path ?? '';

  /// In-memory sessions used when no file folder is available
  /// (e.g. running in a browser to preview the UI).
  final Map<String, Map<String, dynamic>> _memorySessions = {};
  String _memoryLegacy = '';
  List<String> _memoryForbidden = [];

  /// True when running without a real folder (browser preview).
  bool get isMemoryOnly => _base == null;

  Future<void> init() async {
    try {
      // Never let a missing/slow platform folder hang the boot
      // (widget tests have no native side; network drives can stall).
      final docs = await getApplicationDocumentsDirectory()
          .timeout(const Duration(seconds: 4));
      _base = Directory('${docs.path}${Platform.pathSeparator}WordGraphTool');
      _wordsDir = Directory(
          '${_base!.path}${Platform.pathSeparator}words');
      _sheetsDir = Directory(
          '${_base!.path}${Platform.pathSeparator}sheets');
      _imagesDir = Directory(
          '${_base!.path}${Platform.pathSeparator}images');
      await _base!.create(recursive: true);
      await _wordsDir!.create(recursive: true);
      await _sheetsDir!.create(recursive: true);
      await _imagesDir!.create(recursive: true);
      _legacySheetFile = File(
          '${_base!.path}${Platform.pathSeparator}sheet.txt');
      _forbiddenFile = File(
          '${_base!.path}${Platform.pathSeparator}forbidden.txt');
    } catch (_) {
      // No documents folder (e.g. web preview): keep everything in memory.
      _base = null;
      _wordsDir = null;
      _sheetsDir = null;
      _imagesDir = null;
      _legacySheetFile = null;
      _forbiddenFile = null;
    }
  }

  /// Copy a picked picture into the local images folder.
  /// Returns the stored `images/<name>` reference, or null on failure.
  Future<String?> importImageFile(String sourcePath) async {
    try {
      if (_imagesDir == null) return null;
      final ext = sourcePath.split('.').last.toLowerCase();
      final safeExt = RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext) ? ext : 'png';
      final name =
          '${DateTime.now().millisecondsSinceEpoch}.$safeExt';
      await File(sourcePath)
          .copy('${_imagesDir!.path}${Platform.pathSeparator}$name');
      return 'images/$name';
    } catch (_) {
      return null;
    }
  }

  /// Resolve an image reference to something displayable.
  /// Returns a local file path, or the URL untouched for network images.
  String? resolveImage(String ref) {
    final t = ref.trim();
    if (t.isEmpty || t.startsWith('mem:')) return null;
    if (t.startsWith('http://') || t.startsWith('https://')) {
      return t;
    }
    if (_base == null) return null;
    final rel = t.startsWith('images/') ? t : 'images/$t';
    return '${_base!.path}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';
  }

  // ---- Forbidden words (one per line, auto-struck while writing) ----
  static List<String> normalizeForbidden(Iterable<String> words) {
    final seen = <String>{};
    for (final w in words) {
      final k = w.trim().toLowerCase();
      if (k.isNotEmpty) seen.add(k);
    }
    final list = seen.toList()..sort();
    return list;
  }

  Future<List<String>> loadForbidden() async {
    if (_forbiddenFile == null) {
      return normalizeForbidden(_memoryForbidden);
    }
    try {
      if (!await _forbiddenFile!.exists()) return [];
      final lines = await _forbiddenFile!.readAsLines();
      return normalizeForbidden(lines);
    } catch (_) {
      return [];
    }
  }

  Future<void> saveForbidden(List<String> words) async {
    final clean = normalizeForbidden(words);
    if (_forbiddenFile == null) {
      _memoryForbidden = clean;
      return;
    }
    try {
      await _forbiddenFile!.writeAsString('${clean.join('\n')}\n');
    } catch (_) {
      // Silent: never interrupt for IO errors.
    }
  }

  // ---- Groq API key (user-supplied, never shipped) ----
  String _memoryAiKey = '';

  File? get _aiKeyFile => _base == null
      ? null
      : File(
          '${_base!.path}${Platform.pathSeparator}groq_key.txt');

  Future<String> loadAiKey() async {
    final file = _aiKeyFile;
    if (file == null) return _memoryAiKey.trim();
    try {
      if (!await file.exists()) return '';
      return (await file.readAsString()).trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> saveAiKey(String key) async {
    final clean = key.trim();
    final file = _aiKeyFile;
    if (file == null) {
      _memoryAiKey = clean;
      return;
    }
    try {
      await file.writeAsString(clean);
    } catch (_) {
      // Silent: never interrupt for IO errors.
    }
  }
  List<String> _memoryFolders = [];
  List<String> _memoryLearned = [];
  List<Map<String, dynamic>> _memoryGrammar = [];

  File? get _grammarFile => _base == null
      ? null
      : File(
          '${_base!.path}${Platform.pathSeparator}grammar.json');

  /// Grammar reference sentences, in saved order.
  Future<List<GrammarItem>> loadGrammar() async {
    List<dynamic> raw;
    if (_grammarFile == null) {
      raw = _memoryGrammar;
    } else {
      try {
        final file = _grammarFile!;
        if (!await file.exists()) return [];
        raw = jsonDecode(await file.readAsString()) as List;
      } catch (_) {
        return [];
      }
    }
    final out = <GrammarItem>[];
    for (final e in raw) {
      final item = GrammarItem.fromJson(e);
      if (item != null) out.add(item);
    }
    return out;
  }

  Future<void> saveGrammar(List<GrammarItem> items) async {
    final raw = [for (final i in items) i.toJson()];
    if (_grammarFile == null) {
      _memoryGrammar =
          raw.map((e) => Map<String, dynamic>.of(e)).toList();
      return;
    }
    try {
      await _grammarFile!.writeAsString(jsonEncode(raw));
    } catch (_) {
      // Silent: never interrupt for IO errors.
    }
  }

  File? get _foldersFile => _base == null
      ? null
      : File(
          '${_base!.path}${Platform.pathSeparator}folders.txt');

  File? get _learnedFile => _base == null
      ? null
      : File(
          '${_base!.path}${Platform.pathSeparator}learned.txt');

  Future<List<String>> loadLearned() async {
    final file = _learnedFile;
    if (file == null) return List.of(_memoryLearned);
    try {
      if (!await file.exists()) return [];
      return normalizeForbidden(await file.readAsLines());
    } catch (_) {
      return [];
    }
  }

  Future<void> saveLearned(List<String> words) async {
    final clean = normalizeForbidden(words);
    final file = _learnedFile;
    if (file == null) {
      _memoryLearned = clean;
      return;
    }
    try {
      await file.writeAsString('${clean.join('\n')}\n');
    } catch (_) {
      // Silent: never interrupt for IO errors.
    }
  }

  static List<String> normalizeFolders(Iterable<String> folders) {
    final seen = <String>{};
    for (final f in folders) {
      final t = f.trim();
      if (t.isNotEmpty) seen.add(t);
    }
    final list = seen.toList()..sort();
    return list;
  }

  Future<List<String>> loadFolders() async {
    final file = _foldersFile;
    if (file == null) return List.of(_memoryFolders);
    try {
      if (!await file.exists()) return [];
      return normalizeFolders(await file.readAsLines());
    } catch (_) {
      return [];
    }
  }

  Future<void> saveFolders(List<String> folders) async {
    final clean = normalizeFolders(folders);
    final file = _foldersFile;
    if (file == null) {
      _memoryFolders = clean;
      return;
    }
    try {
      await file.writeAsString('${clean.join('\n')}\n');
    } catch (_) {
      // Silent: never interrupt for IO errors.
    }
  }

  // ---- Writing sessions ----
  String _sessionFile(String id) =>
      '${_sheetsDir!.path}${Platform.pathSeparator}$id.json';

  String _newId() =>
      '${DateTime.now().millisecondsSinceEpoch}-${_memorySessions.length}';

  static String normalizeFolder(String? folder) {
    final f = (folder ?? '').trim();
    return f.isEmpty ? 'Notes' : f;
  }

  /// Sessions, newest first.
  Future<List<WritingSession>> loadSessions() async {
    if (_sheetsDir == null) {
      final list = _memorySessions.entries
          .map((e) => WritingSession(
              e.key,
              (e.value['title'] as String?)?.trim().isEmpty ?? true
                  ? 'Untitled'
                  : (e.value['title'] as String),
              (e.value['updatedAt'] as int?) ?? 0,
              folder: normalizeFolder(e.value['folder'] as String?),
              videoUrl: _cleanVideo(e.value['video'] as String?)))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    }
    final out = <WritingSession>[];
    try {
      await for (final ent in _sheetsDir!.list()) {
        if (ent is! File || !ent.path.endsWith('.json')) continue;
        final base = ent.path.split(Platform.pathSeparator).last;
        if (base.endsWith('.bak.json')) continue; // safety copies
        try {
          final raw =
              jsonDecode(await ent.readAsString()) as Map<String, dynamic>;
          final id = base.substring(0, base.length - 5);
          final title = (raw['title'] as String?)?.trim();
          out.add(WritingSession(
              id,
              title == null || title.isEmpty ? 'Untitled' : title,
              (raw['updatedAt'] as int?) ?? 0,
              folder: normalizeFolder(raw['folder'] as String?),
              videoUrl: _cleanVideo(raw['video'] as String?)));
        } catch (_) {
          continue;
        }
      }
    } catch (_) {}
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// Delta JSON for a session, or null when it has no saved content yet.
  Future<String?> loadSessionDelta(String id) async {
    if (_sheetsDir == null) {
      return _memorySessions[id]?['delta'] as String?;
    }
    try {
      final file = File(_sessionFile(id));
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return raw['delta'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSession(String id, String title, String deltaJson,
      {String folder = 'Notes', String? video}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cleanFolder = normalizeFolder(folder);
    final videoUrl = video ?? await _existingVideo(id);
    if (_sheetsDir == null) {
      _memorySessions[id] = {
        'title': title,
        'updatedAt': now,
        'delta': deltaJson,
        'folder': cleanFolder,
        'video': videoUrl,
      };
      return;
    }
    try {
      final content = jsonEncode({
        'title': title,
        'updatedAt': now,
        'delta': deltaJson,
        'folder': cleanFolder,
        'video': videoUrl,
      });
      final file = File(_sessionFile(id));
      // Rotate a backup first: if anything ever writes a bad version,
      // the previous one survives next to it as <id>.bak.json.
      try {
        if (await file.exists()) {
          final prev = await file.readAsString();
          if (prev != content) {
            await File('${_sessionFile(id)}.bak.json')
                .writeAsString(prev);
          }
        }
      } catch (_) {}
      await file.writeAsString(content);
    } catch (_) {
      // Silent: never interrupt typing for IO errors.
    }
  }

  /// Video link already stored for [id] (so plain content saves that do
  /// not mention video never wipe an attached link).
  Future<String> _existingVideo(String id) async {
    try {
      if (_sheetsDir == null) {
        return (_memorySessions[id]?['video'] as String?) ?? '';
      }
      final file = File(_sessionFile(id));
      if (!await file.exists()) return '';
      final raw =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (raw['video'] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Salvage plain text from a delta that no longer parses as a document
  /// (strict formatting must never blank someone's words). Null = hopeless.
  static String? recoverPlainText(String? deltaJson) {
    if (deltaJson == null || deltaJson.isEmpty) return null;
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) return null;
      final buf = StringBuffer();
      for (final op in decoded) {
        if (op is Map && op['insert'] is String) {
          buf.write(op['insert'] as String);
        }
      }
      final text = buf.toString();
      return text.trim().isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  Future<WritingSession> createSession(String title,
      {String folder = 'Notes'}) async {
    final id = _newId();
    await saveSession(id, title, '', folder: folder);
    return WritingSession(id, title, DateTime.now().millisecondsSinceEpoch,
        folder: normalizeFolder(folder));
  }

  Future<void> deleteSession(String id) async {
    _memorySessions.remove(id);
    if (_sheetsDir == null) return;
    try {
      final file = File(_sessionFile(id));
      if (await file.exists()) await file.delete();
      final bak = File('${_sessionFile(id)}.bak.json');
      if (await bak.exists()) await bak.delete();
    } catch (_) {}
  }

  /// Append a crash report for later debugging (desktop only).
  Future<void> logCrash(String text) async {
    if (_base == null) return;
    try {
      final file =
          File('${_base!.path}${Platform.pathSeparator}crash.log');
      var prev = '';
      try {
        if (await file.exists()) prev = await file.readAsString();
      } catch (_) {}
      final entry =
          '--- ${DateTime.now().toIso8601String()} ---\n$text\n';
      final combined = entry + prev;
      await file.writeAsString(
          combined.substring(0, combined.length.clamp(0, 60000)));
    } catch (_) {}
  }
  /// One-time import of the old single sheet.txt (plain text) so nothing
  /// is lost when upgrading. Returns null when there is nothing to import.
  Future<({String title, String deltaJson})?> takeLegacySheet() async {
    String text = '';
    if (_legacySheetFile == null) {
      text = _memoryLegacy;
      _memoryLegacy = '';
    } else {
      try {
        if (!await _legacySheetFile!.exists()) return null;
        text = await _legacySheetFile!.readAsString();
        await _legacySheetFile!.delete();
      } catch (_) {
        return null;
      }
    }
    if (text.trim().isEmpty) return null;
    final firstLine = text.trim().split('\n').first.trim();
    final title = firstLine.length > 40
        ? '${firstLine.substring(0, 40)}…'
        : (firstLine.isEmpty ? 'Old notes' : firstLine);
    return (
      title: title,
      deltaJson: jsonEncode([
        {'insert': '$text\n'}
      ])
    );
  }

  // ---- Graph ----
  String _fileFor(String key) =>
      '${_wordsDir!.path}${Platform.pathSeparator}$key.md';

  /// `key` must already be normalized (lowercase).
  String wordFilePath(String key) => _fileFor(key);

  Future<WordGraph> loadGraph() async {
    final graph = WordGraph();
    try {
      if (_wordsDir == null || !await _wordsDir!.exists()) return graph;
      await for (final ent in _wordsDir!.list()) {
        if (ent is! File || !ent.path.endsWith('.md')) continue;
        try {
          final content = await ent.readAsString();
          final node = parseWordFile(content);
          if (node == null) continue;
          final key = WordGraph.norm(node.name);
          if (key.isEmpty) continue;
          graph.nodes[key] = node;
        } catch (_) {
          continue;
        }
      }
      // Scrub dangling refs so UI never shows ghosts.
      for (final n in graph.nodes.values) {
        n.links = n.links
            .map(WordGraph.norm)
            .where((e) => e.isNotEmpty && graph.nodes.containsKey(e))
            .toSet();
        n.jumps.removeWhere((k, v) =>
            v.trim().isEmpty || !graph.nodes.containsKey(WordGraph.norm(k)));
      }
    } catch (_) {}
    return graph;
  }

  /// Rewrite every word file; remove files for deleted words.
  Future<void> saveGraph(WordGraph graph) async {
    try {
      if (_wordsDir == null) return;
      // Normalize all refs before writing.
      for (final n in graph.nodes.values) {
        n.name = n.name.trim().toLowerCase();
      }
      for (final entry in graph.nodes.entries) {
        final file = File(_fileFor(entry.key));
        await file.writeAsString(serializeWordFile(entry.value));
      }
      // Delete stale files.
      await for (final ent in _wordsDir!.list()) {
        if (ent is! File || !ent.path.endsWith('.md')) continue;
        final base = ent.path.split(Platform.pathSeparator).last;
        final key = base.substring(0, base.length - 3).toLowerCase();
        if (!graph.nodes.containsKey(key)) {
          try {
            await ent.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> saveGraphDebouncedHelper() async {}

  static String serializeWordFile(WordNode node) {
    final name = node.name.trim().toLowerCase();
    final links = node.links.map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort();
    final buf = StringBuffer()
      ..writeln('# $name')
      ..writeln('links: ${links.join(', ')}');
    if (node.hasPos) {
      buf
        ..writeln('x: ${node.x!.toStringAsFixed(1)}')
        ..writeln('y: ${node.y!.toStringAsFixed(1)}');
    }
    if (node.color != null) {
      buf.writeln('color: ${node.color}');
    }
    final image = node.image?.trim();
    if (image != null && image.isNotEmpty && !image.startsWith('mem:')) {
      buf.writeln('image: $image');
    }
    final jumps = node.jumps.entries
        .where((e) =>
            e.key.trim().isNotEmpty && e.value.trim().isNotEmpty)
        .map((e) => '${e.value.trim()}:${e.key.trim().toLowerCase()}')
        .toList()
      ..sort();
    if (jumps.isNotEmpty) {
      buf.writeln('jumps: ${jumps.join(', ')}');
    }
    final meaning = node.meaning?.trim();
    if (meaning != null && meaning.isNotEmpty) {
      buf.writeln('## meaning');
      buf.writeln(meaning);
    }
    return buf.toString();
  }

  static final _meaningHeader =
      RegExp(r'^#{2,}\s*meaning\s*$', caseSensitive: false);
  static final _knownKey = RegExp(
      r'^(links|parents|children|x|y|color|image|jumps)\s*:',
      caseSensitive: false);

  static WordNode? parseWordFile(String content) {
    String? title;
    Set<String> links = {};
    double? x;
    double? y;
    int? color;
    String? image;
    Map<String, String> jumps = {};
    final meaningBuf = StringBuffer();
    var inMeaning = false;
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trimRight();
      final low = line.trimLeft().toLowerCase();
      if (_meaningHeader.hasMatch(line.trim())) {
        inMeaning = true;
        continue;
      }
      if (inMeaning &&
          (_knownKey.hasMatch(low) || low.startsWith('#'))) {
        inMeaning = false;
      }
      if (inMeaning) {
        if (meaningBuf.isNotEmpty) meaningBuf.writeln();
        meaningBuf.write(line.trim());
        continue;
      }
      final t = line.trim();
      if (t.startsWith('#')) {
        // Only the first header is the word itself.
        title ??= t.replaceFirst(RegExp(r'^#+\s*'), '').trim().toLowerCase();
      } else if (line.toLowerCase().startsWith('links:')) {
        links = _parseList(line.substring('links:'.length));
      } else if (line.toLowerCase().startsWith('parents:') ||
          line.toLowerCase().startsWith('children:')) {
        // Legacy hierarchy files: fold both sides into plain links.
        links = {
          ...links,
          ..._parseList(line.substring(line.indexOf(':') + 1))
        };
      } else if (line.toLowerCase().startsWith('x:')) {
        x = double.tryParse(line.substring(2).trim()) ?? x;
      } else if (line.toLowerCase().startsWith('y:')) {
        y = double.tryParse(line.substring(2).trim()) ?? y;
      } else if (line.toLowerCase().startsWith('color:')) {
        color = int.tryParse(line.substring('color:'.length).trim()) ??
            color;
      } else if (line.toLowerCase().startsWith('image:')) {
        final v = line.substring('image:'.length).trim();
        if (v.isNotEmpty) image = v;
      } else if (line.toLowerCase().startsWith('jumps:')) {
        for (final part in line.substring('jumps:'.length).split(',')) {
          final idx = part.indexOf(':');
          if (idx < 0) continue;
          final num = part.substring(0, idx).trim();
          final other = part.substring(idx + 1).trim().toLowerCase();
          if (num.isNotEmpty && other.isNotEmpty) {
            jumps[other] = num;
          }
        }
      }
    }
    if (title == null || title.isEmpty) return null;
    links.remove(title);
    jumps.remove(title);
    final meaning = meaningBuf.toString().trim();
    return WordNode(title,
        links: links,
        x: x,
        y: y,
        color: color,
        meaning: meaning.isEmpty ? null : meaning,
        image: image,
        jumps: jumps);
  }

  static Set<String> _parseList(String s) {
    return s
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
  }
}

/// Simple debounce helper for silent auto-save (~500ms after last keystroke).
class Debouncer {
  final Duration delay;
  Timer? _t;
  Debouncer(this.delay);
  void call(void Function() action) {
    _t?.cancel();
    _t = Timer(delay, action);
  }

  void dispose() => _t?.cancel();
}
