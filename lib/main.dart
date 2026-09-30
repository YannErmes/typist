import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'graph_model.dart';
import 'graph_view.dart';
import 'sheet_view.dart';
import 'storage.dart';
import 'theme.dart';

void main() {
  // Save crash reports next to the notes so a red screen can be diagnosed
  // from Documents/WordGraphTool/crash.log afterwards.
  FlutterError.onError = (details) {
    crashStorage?.logCrash(
        '${details.exceptionAsString()}\n${details.stack ?? ''}');
    FlutterError.presentError(details);
  };
  runApp(const WordGraphToolApp());
}

/// Storage handle used only for crash logging (set once the shell boots).
StorageService? crashStorage;

class WordGraphToolApp extends StatelessWidget {
  const WordGraphToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Word Graph Tool',
      debugShowCheckedModeBanner: false,
      theme: PaperTheme.theme(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      home: const HomeShell(),
    );
  }
}

/// Two views: Sheet (free writing) and Graph (settings / word network).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final StorageService _storage = StorageService();
  final WordGraph _graph = WordGraph();
  final GlobalKey<SheetViewState> _sheetKey = GlobalKey<SheetViewState>();

  int _tab = 0;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    crashStorage = _storage;
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _storage.init();
      final loaded = await _storage.loadGraph();
      _graph.nodes.clear();
      _graph.nodes.addAll(loaded.nodes);
      // Seed a tiny example on first run so @ / # can be tried immediately.
      if (_graph.isEmpty) {
        _graph.ensure('eat');
        _graph.ensure('orange');
        _graph.ensure('tomato');
        _graph.ensure('meal');
        _graph.linkParentChild('meal', 'eat');
        _graph.linkParentChild('eat', 'orange');
        _graph.linkParentChild('eat', 'tomato');
        await _storage.saveGraph(_graph);
      }
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onGraphChanged() {
    setState(() {});
    _sheetKey.currentState?.refreshGraph();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Image.asset('assets/logo.png',
                  width: 28, height: 28),
            ),
            const SizedBox(width: 10),
            const Text('Word Graph Tool',
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => setState(() => _tab = 0),
            icon: Icon(Icons.edit_note,
                color: _tab == 0 ? PaperTheme.ink : PaperTheme.inkSoft),
            label: Text('Sheet',
                style: TextStyle(
                    color:
                        _tab == 0 ? PaperTheme.ink : PaperTheme.inkSoft,
                    fontWeight:
                        _tab == 0 ? FontWeight.w700 : FontWeight.normal)),
          ),
          TextButton.icon(
            onPressed: () => setState(() => _tab = 1),
            icon: Icon(Icons.account_tree,
                color: _tab == 1 ? PaperTheme.ink : PaperTheme.inkSoft),
            label: Text('Graph',
                style: TextStyle(
                    color:
                        _tab == 1 ? PaperTheme.ink : PaperTheme.inkSoft,
                    fontWeight:
                        _tab == 1 ? FontWeight.w700 : FontWeight.normal)),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: !_ready
          ? Center(
              child: _error != null
                  ? Text('Storage error: $_error')
                  : const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
            )
          : IndexedStack(
              index: _tab,
              children: [
                SheetView(
                  key: _sheetKey,
                  storage: _storage,
                  graph: _graph,
                  onGraphChanged: _onGraphChanged,
                ),
                GraphView(
                  storage: _storage,
                  graph: _graph,
                  onGraphChanged: _onGraphChanged,
                ),
              ],
            ),
    );
  }
}
