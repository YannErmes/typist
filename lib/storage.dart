import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'graph_model.dart';

/// All persistence is local files, written silently with dart:io.
/// Layout: [Documents]/WordGraphTool/sheet.txt + words per-word .md files.
class StorageService {
  Directory? _base;
  Directory? _wordsDir;
  File? _sheetFile;

  Directory? get baseDir => _base;
  String get basePath => _base?.path ?? '';

  /// In-memory preview text used when no file folder is available
  /// (e.g. running in a browser to preview the UI).
  String _memorySheet = '';

  /// True when running without a real folder (browser preview).
  bool get isMemoryOnly => _base == null;

  Future<void> init() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      _base = Directory('${docs.path}${Platform.pathSeparator}WordGraphTool');
      _wordsDir = Directory(
          '${_base!.path}${Platform.pathSeparator}words');
      await _base!.create(recursive: true);
      await _wordsDir!.create(recursive: true);
      _sheetFile = File(
          '${_base!.path}${Platform.pathSeparator}sheet.txt');
      if (!await _sheetFile!.exists()) {
        await _sheetFile!.writeAsString('');
      }
    } catch (_) {
      // No documents folder (e.g. web preview): keep everything in memory.
      _base = null;
      _wordsDir = null;
      _sheetFile = null;
    }
  }

  // ---- Sheet ----
  Future<String> loadSheet() async {
    if (_sheetFile == null) return _memorySheet;
    try {
      if (!await _sheetFile!.exists()) return '';
      return await _sheetFile!.readAsString();
    } catch (_) {
      return '';
    }
  }

  Future<void> saveSheet(String text) async {
    if (_sheetFile == null) {
      _memorySheet = text;
      return;
    }
    try {
      await _sheetFile!.writeAsString(text);
    } catch (_) {
      // Silent: never interrupt typing for IO errors.
    }
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
    return '# $name\nparents: ${parents.join(', ')}\nchildren: ${children.join(', ')}\n';
  }

  static WordNode? parseWordFile(String content) {
    String? title;
    Set<String> parents = {};
    Set<String> children = {};
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('#')) {
        title = line.replaceFirst(RegExp(r'^#+\s*'), '').trim().toLowerCase();
      } else if (line.toLowerCase().startsWith('parents:')) {
        parents = _parseList(line.substring('parents:'.length));
      } else if (line.toLowerCase().startsWith('children:')) {
        children = _parseList(line.substring('children:'.length));
      }
    }
    if (title == null || title.isEmpty) return null;
    parents.remove(title);
    children.remove(title);
    return WordNode(title, parents: parents, children: children);
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
