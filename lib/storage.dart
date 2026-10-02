import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'graph_model.dart';

/// One titled writing session (a document).
class WritingSession {
  final String id;
  String title;
  String folder;
  int updatedAt;
  WritingSession(this.id, this.title, this.updatedAt,
      {this.folder = 'Notes'});
}

/// All persistence is local files, written silently with dart:io.
/// Layout: [Documents]/WordGraphTool/`sheets/<id>.json` (titled sessions
/// with Quill delta content) + words per-word .md files.
class StorageService {
  Directory? _base;
  Directory? _wordsDir;
  Directory? _sheetsDir;
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
      await _base!.create(recursive: true);
      await _wordsDir!.create(recursive: true);
      await _sheetsDir!.create(recursive: true);
      _legacySheetFile = File(
          '${_base!.path}${Platform.pathSeparator}sheet.txt');
      _forbiddenFile = File(
          '${_base!.path}${Platform.pathSeparator}forbidden.txt');
    } catch (_) {
      // No documents folder (e.g. web preview): keep everything in memory.
      _base = null;
      _wordsDir = null;
      _sheetsDir = null;
      _legacySheetFile = null;
      _forbiddenFile = null;
    }
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

  // ---- Explicit folders (so empty folders survive a restart) ----
  List<String> _memoryFolders = [];

  File? get _foldersFile => _base == null
      ? null
      : File(
          '${_base!.path}${Platform.pathSeparator}folders.txt');

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
              folder: normalizeFolder(e.value['folder'] as String?)))
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
              folder: normalizeFolder(raw['folder'] as String?)));
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
      {String folder = 'Notes'}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cleanFolder = normalizeFolder(folder);
    if (_sheetsDir == null) {
      _memorySessions[id] = {
        'title': title,
        'updatedAt': now,
        'delta': deltaJson,
        'folder': cleanFolder,
      };
      return;
    }
    try {
      final content = jsonEncode({
        'title': title,
        'updatedAt': now,
        'delta': deltaJson,
        'folder': cleanFolder,
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
    final meaning = node.meaning?.trim();
    if (meaning != null && meaning.isNotEmpty) {
      buf.writeln('## meaning');
      buf.writeln(meaning);
    }
    return buf.toString();
  }

  static final _meaningHeader =
      RegExp(r'^#{2,}\s*meaning\s*$', caseSensitive: false);
  static final _knownKey =
      RegExp(r'^(links|parents|children|x|y|color)\s*:', caseSensitive: false);

  static WordNode? parseWordFile(String content) {
    String? title;
    Set<String> links = {};
    double? x;
    double? y;
    int? color;
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
      }
    }
    if (title == null || title.isEmpty) return null;
    links.remove(title);
    final meaning = meaningBuf.toString().trim();
    return WordNode(title,
        links: links,
        x: x,
        y: y,
        color: color,
        meaning: meaning.isEmpty ? null : meaning);
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
