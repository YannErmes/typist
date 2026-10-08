import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'computer_video.dart';
import 'forbidden_view.dart';
import 'grammar_view.dart';
import 'graph_model.dart';
import 'graph_view.dart';
import 'repetition_view.dart';
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
  // mpv must be loaded before the first Player/VideoController exists,
  // otherwise the native video output is created against an uninitialised
  // library and renders nothing. A failure here costs us the video
  // feature only, so it must not take the whole app down with it.
  WidgetsFlutterBinding.ensureInitialized();
  try {
    ComputerVideo.ensureInitialized();
  } catch (e) {
    debugPrint('media_kit failed to initialise: $e');
  }
  runZonedGuarded(
    () {
      FlutterError.onError = (details) {
        final text = '${details.exceptionAsString()}\n${details.stack ?? ''}';
        CrashCenter.record(text);
        FlutterError.presentError(details);
      };
      runApp(const WordGraphToolApp());
    },
    (error, stack) {
      CrashCenter.record('$error\n$stack');
    },
  );
}

/// Storage handle used only for crash logging (set once the shell boots).
StorageService? crashStorage;

class WordGraphToolApp extends StatelessWidget {
  /// Shared storage (tests inject one instance across restarts).
  final StorageService? storage;
  const WordGraphToolApp({super.key, this.storage});

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
      home: HomeShell(storage: storage),
    );
  }
}

/// Four views: Sheet (writing), Graph (word network), Banned (forbidden),
/// Grammar (structures), Practice (spaced repetition).
class HomeShell extends StatefulWidget {
  final StorageService? storage;
  const HomeShell({super.key, this.storage});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final StorageService _storage;
  final WordGraph _graph = WordGraph();
  final GlobalKey<SheetViewState> _sheetKey = GlobalKey<SheetViewState>();

  /// Forbidden words, shared live with the writing + banned views.
  final List<String> _forbidden = [];

  int _tab = 0;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? StorageService();
    crashStorage = _storage;
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _storage.init();
      final loaded = await _storage.loadGraph();
      _graph.nodes.clear();
      _graph.nodes.addAll(loaded.nodes);
      final banned = await _storage.loadForbidden();
      _forbidden
        ..clear()
        ..addAll(banned);
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

  /// Small floating nav pill (always on top of the current tab).
  Widget _navPill() {
    return Material(
      elevation: 6,
      shadowColor: const Color(0xFF3E3A31).withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(24),
      color: PaperTheme.surface,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: PaperTheme.lineThin),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pillItem(0, Icons.edit_note, 'Sheet'),
            _pillItem(1, Icons.account_tree, 'Graph'),
            _pillItem(2, Icons.block, 'Banned'),
            _pillItem(3, Icons.spellcheck, 'Grammar'),
            _pillItem(4, Icons.repeat_outlined, 'Practice'),
          ],
        ),
      ),
    );
  }

  Widget _pillItem(int index, IconData icon, String label) {
    final active = _tab == index;
    return InkWell(
      onTap: () => setState(() => _tab = index),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? PaperTheme.card : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 17,
              color: active ? PaperTheme.ink : PaperTheme.inkSoft,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: active ? PaperTheme.ink : PaperTheme.inkSoft,
                fontWeight: active ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
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
              child: Image.asset('assets/logo.png', width: 28, height: 28),
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'Word Graph Tool',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          // Full-bleed tabs: content flows behind the floating pill.
          if (!_ready)
            Center(
              child: _error != null
                  ? Text('Storage error: $_error')
                  : const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
            )
          else
            IndexedStack(
              index: _tab,
              children: [
                SheetView(
                  key: _sheetKey,
                  storage: _storage,
                  graph: _graph,
                  forbidden: _forbidden,
                  onGraphChanged: _onGraphChanged,
                ),
                GraphView(
                  storage: _storage,
                  graph: _graph,
                  onGraphChanged: _onGraphChanged,
                ),
                ForbiddenPage(storage: _storage, words: _forbidden),
                GrammarPage(storage: _storage),
                RepetitionView(
                  storage: _storage,
                  graph: _graph,
                  onGraphChanged: _onGraphChanged,
                ),
              ],
            ),
          if (_ready)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _navPill(),
                  ),
                ),
              ),
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
        title: const Text(
          'What broke',
          style: TextStyle(
            color: PaperTheme.ink,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: SizedBox(
          width: 520,
          height: 380,
          child: SingleChildScrollView(
            child: SelectableText(
              crash.length > 6000 ? crash.substring(0, 6000) : crash,
              style: const TextStyle(color: PaperTheme.ink, fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: crash));
              Navigator.of(ctx).pop();
            },
            child: const Text(
              'Copy',
              style: TextStyle(
                color: PaperTheme.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              CrashCenter.lastCrash.value = null;
              Navigator.of(ctx).pop();
            },
            child: const Text(
              'Dismiss',
              style: TextStyle(color: PaperTheme.inkSoft),
            ),
          ),
        ],
      ),
    );
  }
}
