import 'package:flutter/material.dart';

import 'blast_demo.dart';
import 'blast_game.dart';
import 'blast_image.dart';
import 'blast_model.dart';
import 'graph_images.dart';
import 'graph_model.dart';
import 'storage.dart';
import 'theme.dart';

/// The Blast page: a bundle studio whose picture words come straight from
/// the mind-map, plus the typing shooter itself.
class BlastView extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  final VoidCallback onGraphChanged;

  /// Asks the shell to open the real Graph page in picture-picker mode.
  /// Reusing that page matters: browser-picked pictures live in its state.
  final VoidCallback onRequestPick;

  const BlastView({
    super.key,
    required this.storage,
    required this.graph,
    required this.onGraphChanged,
    required this.onRequestPick,
  });

  @override
  State<BlastView> createState() => BlastViewState();
}

class BlastViewState extends State<BlastView> {
  List<BlastBundle> _bundles = const [];
  bool _loaded = false;
  BlastBundle? _editing;
  String? _playingId;

  final TextEditingController _titleCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _titleCtrl.addListener(_onTitleChanged);
    _reload();
  }

  @override
  void dispose() {
    _titleCtrl.removeListener(_onTitleChanged);
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final bundles = await widget.storage.loadBlastBundles();
    if (!mounted) return;
    setState(() {
      _bundles = bundles;
      if (_editing != null) {
        for (final b in _bundles) {
          if (b.id == _editing!.id) {
            _editing = b;
            break;
          }
        }
      }
      _loaded = true;
    });
  }

  @visibleForTesting
  List<BlastBundle> get debugBundles => _bundles;

  @visibleForTesting
  BlastBundle? get debugEditing => _editing;

  @visibleForTesting
  Future<void> debugCreateBundle(String title, List<BlastItem> items) async {
    final bundle = BlastBundle(
      id: 'b-${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      items: List<BlastItem>.of(items),
    );
    final next = [bundle, ..._bundles];
    await widget.storage.saveBlastBundles(next);
    if (!mounted) return;
    setState(() => _bundles = next);
  }

  // ---- Bundle actions ----

  Future<void> _newBundle() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final bundle = BlastBundle(
      id: 'b-$now',
      title: 'Untitled bundle',
      items: const [],
    );
    final next = [bundle, ..._bundles];
    await widget.storage.saveBlastBundles(next);
    if (!mounted) return;
    setState(() {
      _bundles = next;
      _editing = bundle;
      _titleCtrl.text = bundle.title == 'Untitled bundle' ? '' : bundle.title;
    });
  }

  /// Adds ready-made picture bundles so the shooting game can be tried
  /// immediately. Existing bundles are never overwritten.
  Future<void> _loadDemo() async {
    final demos = blastDemoBundles();
    final have = _bundles.map((b) => b.id).toSet();
    final missing = demos.where((b) => !have.contains(b.id)).toList();
    if (missing.isEmpty) {
      _notice('Demo bundles are already in your library.');
      return;
    }
    final next = [...missing, ..._bundles];
    await widget.storage.saveBlastBundles(next);
    if (!mounted) return;
    setState(() => _bundles = next);
    _notice('Added ${missing.length} demo bundles '
        '(${missing.fold<int>(0, (n, b) => n + b.items.length)} pictures).');
  }

  void _openEditor(BlastBundle bundle) {
    setState(() {
      _editing = bundle;
      _titleCtrl.text = bundle.title == 'Untitled bundle' ? '' : bundle.title;
    });
  }

  void _backToLibrary() {
    setState(() {
      _editing = null;
      _playingId = null;
    });
  }

  Future<void> _persist() async {
    if (_editing == null) return;
    await widget.storage.saveBlastBundles(_bundles);
  }

  void _onTitleChanged() {
    final editing = _editing;
    if (editing == null || !_loaded) return;
    editing.title = _titleCtrl.text.trim().isEmpty
        ? 'Untitled bundle'
        : _titleCtrl.text.trim();
    _persist();
    setState(() {}); // refresh the rail and card titles
  }

  Future<void> _delete(BlastBundle bundle) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PaperTheme.paper,
        title: const Text('Delete this bundle?',
            style: TextStyle(
                color: PaperTheme.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700)),
        content: Text('"${bundle.title}" will be removed.',
            style:
                const TextStyle(color: PaperTheme.inkSoft, fontSize: 12)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: PaperTheme.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(color: Color(0xFF8F2F25))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final next = _bundles.where((b) => b.id != bundle.id).toList();
    await widget.storage.saveBlastBundles(next);
    if (!mounted) return;
    setState(() {
      _bundles = next;
      if (_editing?.id == bundle.id) _editing = null;
    });
  }

  void _removeItem(BlastItem item) {
    final editing = _editing;
    if (editing == null) return;
    setState(() {
      editing.items =
          editing.items.where((x) => x.word != item.word).toList();
    });
    _persist();
  }

  void _play(BlastBundle bundle) {
    if (bundle.items.isEmpty) {
      _notice('Add some picture words from the map first.');
      return;
    }
    setState(() => _playingId = bundle.id);
  }

  void _notice(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            style: const TextStyle(color: PaperTheme.ink, fontSize: 12)),
        backgroundColor: PaperTheme.card,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ---- Map picker ----

  /// The shell switches to the real Graph page in pick mode; that keeps
  /// browser-picked picture bytes in the Graph page that already owns them.
  void _pickFromMap() => widget.onRequestPick();

  /// Called by the shell whenever a word is tapped in Graph pick mode.
  void addPickedWord(String word) {
    final editing = _editing;
    if (editing == null) return;
    final node = widget.graph.get(word);
    if (node == null || !node.hasImage) {
      _notice('"$word" has no picture — pick a word with an image.');
      return;
    }
    final ref = node.image!.trim();
    String image = ref;
    if (ref.startsWith('mem:')) {
      final bytes = GraphImages.get(ref);
      if (bytes == null) {
        _notice('That picture is no longer available.');
        return;
      }
      image = blastDataUrl(bytes);
    }
    if (editing.items.any((i) => i.word == word)) {
      _notice('"$word" is already in this bundle.');
      return;
    }
    setState(() {
      editing.items = [
        ...editing.items,
        BlastItem(word: word, image: image),
      ];
    });
    _persist();
    _notice('Added "$word" — keep picking or tap Done on the map.');
  }

  // ---- Layout ----

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
        child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    BlastBundle? playing;
    if (_playingId != null) {
      for (final b in _bundles) {
        if (b.id == _playingId) {
          playing = b;
          break;
        }
      }
    }
    if (playing != null) {
      return BlastGame(
        storage: widget.storage,
        bundle: playing,
        onExit: () => setState(() => _playingId = null),
      );
    }
    return Container(
      color: PaperTheme.paper,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildRail(),
          Expanded(
            child: _editing == null ? _buildLibrary() : _buildEditor(),
          ),
        ],
      ),
    );
  }

  Widget _buildRail() {
    return Container(
      width: 216,
      decoration: const BoxDecoration(
        color: PaperTheme.paperDark,
        border: Border(right: BorderSide(color: PaperTheme.lineThin)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 6, 4),
            child: Row(
              children: [
                const Text('BUNDLES',
                    style: TextStyle(
                        color: PaperTheme.inkSoft,
                        fontSize: 11,
                        letterSpacing: 1.2)),
                const Spacer(),
                IconButton(
                  tooltip: 'New bundle',
                  onPressed: _newBundle,
                  icon:
                      const Icon(Icons.add, size: 18, color: PaperTheme.ink),
                ),
              ],
            ),
          ),
          Expanded(
            child: _bundles.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'No bundles yet. Create one, then pick picture words '
                      'from the map.',
                      style:
                          TextStyle(color: PaperTheme.inkSoft, fontSize: 11),
                    ),
                  )
                : ListView.builder(
                    itemCount: _bundles.length,
                    itemBuilder: (context, i) => _railRow(_bundles[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _railRow(BlastBundle bundle) {
    final active = _editing?.id == bundle.id || _playingId == bundle.id;
    return InkWell(
      onTap: () => _openEditor(bundle),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        decoration: BoxDecoration(
          color: active ? PaperTheme.chip : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(bundle.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: PaperTheme.ink,
                          fontSize: 13,
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.normal)),
                  const SizedBox(height: 2),
                  Text('${bundle.items.length} picture words',
                      style: const TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 10)),
                ],
              ),
            ),
            InkWell(
              onTap: () => _delete(bundle),
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
    );
  }

  Widget _thumb(String ref, {double size = 44}) {
    final provider = blastImageProvider(widget.storage, ref);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: PaperTheme.surface,
        border: Border.all(color: PaperTheme.lineThin),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: provider == null
          ? const Icon(Icons.image_outlined,
              size: 18, color: PaperTheme.inkSoft)
          : Image(
              image: provider,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.broken_image_outlined,
                      size: 18, color: PaperTheme.inkSoft),
            ),
    );
  }

  Widget _buildLibrary() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 22),
            decoration: BoxDecoration(
              color: const Color(0xFFEFE8D6),
              border: Border.all(color: PaperTheme.lineThin),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Typing bundles',
                              style: TextStyle(
                                  color: PaperTheme.ink,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700)),
                          SizedBox(height: 2),
                          Text(
                            'Picture words picked from your map — '
                            'type their names to shoot them.',
                            style: TextStyle(
                                color: PaperTheme.inkSoft, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: PaperTheme.ink,
                      ),
                      onPressed: _loadDemo,
                      icon: const Icon(Icons.auto_awesome_outlined, size: 15),
                      label: const Text('Load demo bundles'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: PaperTheme.ink,
                        foregroundColor: PaperTheme.paper,
                      ),
                      onPressed: _newBundle,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('New bundle'),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (_bundles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 50),
                    child: Text(
                      'No bundles yet. Create one, then use "Pick from map" '
                      'to add picture words.',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: PaperTheme.inkSoft, fontSize: 13),
                    ),
                  )
                else
                  Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      for (final bundle in _bundles)
                        SizedBox(width: 270, child: _bundleCard(bundle)),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bundleCard(BlastBundle bundle) {
    final thumbs = bundle.items.take(3).map((i) => _thumb(i.image)).toList();
    if (bundle.items.length > 3) {
      thumbs.add(Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: PaperTheme.surface,
          border: Border.all(color: PaperTheme.lineThin),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('+${bundle.items.length - 3}',
            style: const TextStyle(color: PaperTheme.inkSoft, fontSize: 11)),
      ));
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PaperTheme.surface,
        border: Border.all(color: PaperTheme.lineThin),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(bundle.title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: PaperTheme.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('${bundle.items.length} picture words',
              style: const TextStyle(
                  color: PaperTheme.inkSoft, fontSize: 11)),
          const SizedBox(height: 12),
          Row(children: [
            for (final t in thumbs) ...[t, const SizedBox(width: 6)],
            if (thumbs.isEmpty)
              const Text('no pictures yet',
                  style: TextStyle(color: PaperTheme.inkSoft, fontSize: 11)),
          ]),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: PaperTheme.ink,
                    foregroundColor: PaperTheme.paper,
                  ),
                  onPressed: () => _play(bundle),
                  icon: const Icon(Icons.play_arrow, size: 15),
                  label: const Text('Play'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _openEditor(bundle),
                  child: const Text('Edit',
                      style: TextStyle(color: PaperTheme.ink)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    final bundle = _editing!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 22),
            decoration: BoxDecoration(
              color: const Color(0xFFEFE8D6),
              border: Border.all(color: PaperTheme.lineThin),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _backToLibrary,
                      icon: const Icon(Icons.arrow_back, size: 15),
                      label: const Text('All bundles'),
                      style: TextButton.styleFrom(
                          foregroundColor: PaperTheme.inkSoft),
                    ),
                    const Spacer(),
                    const Text('Saved on this device',
                        style: TextStyle(
                            color: PaperTheme.inkSoft, fontSize: 10)),
                  ],
                ),
                TextField(
                  controller: _titleCtrl,
                  style: const TextStyle(
                      color: PaperTheme.ink,
                      fontSize: 24,
                      fontWeight: FontWeight.w700),
                  decoration: const InputDecoration(
                    hintText: 'Untitled bundle',
                    hintStyle: TextStyle(color: PaperTheme.inkSoft),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 4),
                const Text('Give the bundle a name, then pick picture words.',
                    style: TextStyle(
                        color: PaperTheme.inkSoft, fontSize: 11)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text('ELEMENTS  ${bundle.items.length}',
                        style: const TextStyle(
                            color: PaperTheme.inkSoft,
                            fontSize: 11,
                            letterSpacing: 1.2)),
                    const Spacer(),
                  ],
                ),
                const SizedBox(height: 8),
                if (bundle.items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      'No elements yet — open the map and pick words that '
                      'have a picture.',
                      style: TextStyle(
                          color: PaperTheme.inkSoft, fontSize: 12),
                    ),
                  )
                else
                  Column(
                    children: [
                      for (final item in bundle.items)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: PaperTheme.surface,
                            border:
                                Border.all(color: PaperTheme.lineThin),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              _thumb(item.image, size: 52),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(item.word,
                                    style: const TextStyle(
                                        color: PaperTheme.ink,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600)),
                              ),
                              InkWell(
                                onTap: () => _removeItem(item),
                                child: const Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(Icons.close,
                                      size: 15,
                                      color: PaperTheme.inkSoft),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: PaperTheme.ink,
                    side: const BorderSide(
                        color: PaperTheme.lineThin,
                        style: BorderStyle.solid),
                  ),
                  onPressed: _pickFromMap,
                  icon: const Icon(Icons.photo_library_outlined, size: 16),
                  label: const Text('Pick from map…'),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: PaperTheme.ink,
                          foregroundColor: PaperTheme.paper,
                        ),
                        onPressed: () => _play(bundle),
                        icon: const Icon(Icons.play_arrow, size: 15),
                        label: const Text('Play now'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _backToLibrary,
                        child: const Text('Done',
                            style: TextStyle(color: PaperTheme.ink)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
