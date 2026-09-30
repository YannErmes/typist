import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'graph_model.dart';
import 'graph_view.dart';
import 'sheet_view.dart';
import 'storage.dart';
import 'theme.dart';

/// In-memory record of the last framework crash, so a red screen can be
/// inspected and copied from inside the app (works in the browser too,
// end where files can't be written).
class CrashCenter {
  static final ValueNotifier<String?> lastCrash = ValueNotifier(null);

  static void record(String text) {
    lastCrash.value = text;
    crashStorage?.logCrash(text);
  }
}

void main() {
  runZonedGuarded(() {
    FlutterError.onError = (details) {
      final text =
          '${details.exceptionAsString()}\n${details.stack ?? ''}';
      CrashCenter.record(text);
      FlutterError.presentError(details);
    };
    runApp(const WordGraphToolApp());
  }, (error, stack) {
    CrashCenter.record('$error\n$stack');
  });
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
      // Seed a tiny example on first run so @ can be tried immediately.
      if (_graph.isEmpty) {
        _graph.connect('meal', 'eat');
        _graph.connect('eat', 'orange');
        _graph.connect('eat', 'tomato');
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
      floatingActionButton: ValueListenableBuilder<String?>(
        valueListenable: CrashCenter.lastCrash,
        builder: (context, crash, _) {
          if (crash == null) return const SizedBox.shrink();
          return FloatingActionButton.small(
            tooltip: 'Something broke — tap to see details',
            backgroundColor: const Color(0xFF8F2F25),
            foregroundColor: Colors.white,
            onPressed: () => _showCrash(context, crash),
            child: const Icon(Icons.bug_report),
          );
        },
      ),
    );
  }

  void _showCrash(BuildContext context, String crash) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF4EEDF),
        title: const Text('What broke',
            style: TextStyle(
                color: PaperTheme.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 520,
          height: 380,
          child: SingleChildScrollView(
            child: SelectableText(
              crash.length > 6000 ? crash.substring(0, 6000) : crash,
              style: const TextStyle(
                  color: PaperTheme.ink, fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: crash));
              Navigator.of(ctx).pop();
            },
            child: const Text('Copy',
                style: TextStyle(
                    color: PaperTheme.ink,
                    fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: () {
              CrashCenter.lastCrash.value = null;
              Navigator.of(ctx).pop();
            },
            child: const Text('Dismiss',
                style: TextStyle(color: PaperTheme.inkSoft)),
          ),
        ],
      ),
    );
  }
}
