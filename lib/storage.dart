import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'graph_model.dart';

/// One titled writing session (a document).
class WritingSession {
  final String id;
  String title;
  int updatedAt;
  WritingSession(this.id, this.title, this.updatedAt);
}

/// All persistence is local files, written silently with dart:io.
/// Layout: [Documents]/WordGraphTool/`sheets/<id>.json` (titled sessions
/// with Quill delta content) + words per-word .md files.
class StorageService {
  Directory? _base;
  Directory? _wordsDir;
  Directory? _sheetsDir;
  File? _legacySheetFile;

  Directory? get baseDir => _base;
  String get basePath => _base?.path ?? '';

  /// In-memory sessions used when no file folder is available
  /// (e.g. running in a browser to preview the UI).
  final Map<String, Map<String, dynamic>> _memorySessions = {};
  String _memoryLegacy = '';

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
    } catch (_) {
      // No documents folder (e.g. web preview): keep everything in memory.
      _base = null;
      _wordsDir = null;
      _sheetsDir = null;
      _legacySheetFile = null;
    }
  }

  // ---- Writing sessions ----
  String _sessionFile(String id) =>
      '${_sheetsDir!.path}${Platform.pathSeparator}$id.json';

  String _newId() =>
      '${DateTime.now().millisecondsSinceEpoch}-${_memorySessions.length}';

  /// Sessions, newest first.
  Future<List<WritingSession>> loadSessions() async {
    if (_sheetsDir == null) {
      final list = _memorySessions.entries
          .map((e) => WritingSession(
              e.key,
              (e.value['title'] as String?)?.trim().isEmpty ?? true
                  ? 'Untitled'
                  : (e.value['title'] as String),
              (e.value['updatedAt'] as int?) ?? 0))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    }
    final out = <WritingSession>[];
    try {
      await for (final ent in _sheetsDir!.list()) {
        if (ent is! File || !ent.path.endsWith('.json')) continue;
        try {
          final raw =
              jsonDecode(await ent.readAsString()) as Map<String, dynamic>;
          final base = ent.path.split(Platform.pathSeparator).last;
          final id = base.substring(0, base.length - 5);
          final title = (raw['title'] as String?)?.trim();
          out.add(WritingSession(id,
              title == null || title.isEmpty ? 'Untitled' : title,
              (raw['updatedAt'] as int?) ?? 0));
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

  Future<void> saveSession(String id, String title, String deltaJson) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_sheetsDir == null) {
      _memorySessions[id] = {
        'title': title,
        'updatedAt': now,
        'delta': deltaJson,
      };
      return;
    }
    try {
      await File(_sessionFile(id)).writeAsString(jsonEncode({
        'title': title,
        'updatedAt': now,
        'delta': deltaJson,
      }));
    } catch (_) {
      // Silent: never interrupt typing for IO errors.
    }
  }

  Future<WritingSession> createSession(String title) async {
    final id = _newId();
    await saveSession(id, title, '');
    return WritingSession(
        id, title, DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> deleteSession(String id) async {
    _memorySessions.remove(id);
    if (_sheetsDir == null) return;
    try {
      final file = File(_sessionFile(id));
      if (await file.exists()) await file.delete();
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
        n.parents = n.parents
            .map(WordGraph.norm)
            .where((e) => e.isNotEmpty && graph.nodes.containsKey(e))
            .toSet();
        n.children = n.children
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
    final parents = node.parents.map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort();
    final children = node.children.map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort();
    final buf = StringBuffer()
      ..writeln('# $name')
      ..writeln('parents: ${parents.join(', ')}')
      ..writeln('children: ${children.join(', ')}');
    if (node.hasPos) {
      buf
        ..writeln('x: ${node.x!.toStringAsFixed(1)}')
        ..writeln('y: ${node.y!.toStringAsFixed(1)}');
    }
    return buf.toString();
  }

  static WordNode? parseWordFile(String content) {
    String? title;
    Set<String> parents = {};
    Set<String> children = {};
    double? x;
    double? y;
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('#')) {
        title = line.replaceFirst(RegExp(r'^#+\s*'), '').trim().toLowerCase();
      } else if (line.toLowerCase().startsWith('parents:')) {
        parents = _parseList(line.substring('parents:'.length));
      } else if (line.toLowerCase().startsWith('children:')) {
        children = _parseList(line.substring('children:'.length));
      } else if (line.toLowerCase().startsWith('x:')) {
        x = double.tryParse(line.substring(2).trim()) ?? x;
      } else if (line.toLowerCase().startsWith('y:')) {
        y = double.tryParse(line.substring(2).trim()) ?? y;
      }
    }
    if (title == null || title.isEmpty) return null;
    parents.remove(title);
    children.remove(title);
    return WordNode(title,
        parents: parents, children: children, x: x, y: y);
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
