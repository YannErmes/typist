import 'package:flutter/material.dart';

import 'storage.dart';
import 'theme.dart';

/// Grammar page: paste example sentences with a given structure,
/// group them by category, and check the ones the AI checker
/// should look for while writing.
class GrammarPage extends StatefulWidget {
  final StorageService storage;

  const GrammarPage({super.key, required this.storage});

  @override
  State<GrammarPage> createState() => _GrammarPageState();
}

class _GrammarPageState extends State<GrammarPage> {
  final _sentenceCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();

  /// Reused for every rename dialog. Never disposed mid-flight: disposing
  /// a dialog controller while its route animates out trips rebuilds that
  /// still reference it (red screen). Disposed once with this state.
  final TextEditingController _nameCtrl = TextEditingController();
  List<GrammarItem> _items = [];
  bool _loaded = false;

  /// Whether the editor offers the AI grammar check. Persisted; the
  /// editor chip disappears while this is off.
  bool _checkEnabled = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _sentenceCtrl.dispose();
    _categoryCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final items = await widget.storage.loadGrammar();
    final enabled = await widget.storage.loadGrammarCheckEnabled();
    if (!mounted) return;
    setState(() {
      _items = items;
      _checkEnabled = enabled;
      _loaded = true;
    });
  }

  Future<void> _toggleCheck(bool v) async {
    setState(() => _checkEnabled = v);
    await widget.storage.saveGrammarCheckEnabled(v);
  }

  Future<void> _save() =>
      widget.storage.saveGrammar(_items);

  Map<String, List<GrammarItem>> _grouped() {
    final map = <String, List<GrammarItem>>{};
    for (final item in _items) {
      map.putIfAbsent(item.category, () => []).add(item);
    }
    final keys = map.keys.toList()..sort();
    return {for (final k in keys) k: map[k]!};
  }

  Future<void> _add() async {
    final text = _sentenceCtrl.text.trim();
    if (text.isEmpty) return;
    var category = _categoryCtrl.text.trim();
    if (category.isEmpty) category = 'General';
    setState(() {
      _items.add(GrammarItem(
        id: '${DateTime.now().millisecondsSinceEpoch}-${_items.length}',
        text: text,
        category: category,
      ));
      _sentenceCtrl.clear();
    });
    await _save();
  }

  Future<void> _toggle(GrammarItem item, bool? v) async {
    setState(() => item.checked = v ?? true);
    await _save();
  }

  Future<void> _delete(GrammarItem item) async {
    setState(() => _items.removeWhere((e) => e.id == item.id));
    await _save();
  }

  Future<void> _renameCategory(String oldName) async {
    final name = await _askName(
        title: 'Rename "$oldName"', initial: oldName);
    if (name == null || !mounted) return;
    setState(() {
      for (final item in _items) {
        if (item.category == oldName) item.category = name;
      }
    });
    await _save();
  }

  Future<void> _deleteCategory(String category) async {
    final leftovers =
        _items.where((e) => e.category == category).toList();
    if (leftovers.isEmpty) return;
    // Never lose sentences: park them under General.
    setState(() {
      for (final item in leftovers) {
        item.category = 'General';
      }
    });
    await _save();
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sentences moved to General.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<String?> _askName(
      {required String title, String? initial}) async {
    _nameCtrl.text = initial ?? '';
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
          controller: _nameCtrl,
          autofocus: true,
          onSubmitted: (_) =>
              Navigator.of(ctx).pop(_nameCtrl.text.trim()),
          style:
              const TextStyle(color: PaperTheme.ink, fontSize: 14),
          decoration: InputDecoration(
            filled: true,
            fillColor: PaperTheme.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: PaperTheme.lineThin),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: PaperTheme.lineThin),
            ),
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
                Navigator.of(ctx).pop(_nameCtrl.text.trim()),
            child: const Text('Save',
                style: TextStyle(
                    color: PaperTheme.ink,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    // NOTE: _nameCtrl is intentionally NOT disposed here (see field docs).
    if (name == null || name.trim().isEmpty) return null;
    return name.trim();
  }

  InputDecoration _field(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle:
          const TextStyle(color: PaperTheme.inkSoft, fontSize: 13),
      filled: true,
      fillColor: const Color(0xFFEFE8D6),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: PaperTheme.lineThin),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: PaperTheme.lineThin),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final checked = _items.where((e) => e.checked).length;
    return Container(
      color: PaperTheme.paper,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Grammar structures${_items.isEmpty ? '' : ' · $checked checked'}',
                style: const TextStyle(
                    color: PaperTheme.ink,
                    fontSize: 20,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'Paste sentences with the structures you practise, group them by category, and check the ones the checker should hunt for.',
                style: TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFE8D6),
                  border: Border.all(color: PaperTheme.lineThin),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Grammar check',
                              style: TextStyle(
                                  color: PaperTheme.ink,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(
                            _checkEnabled
                                ? 'The "grammar check" button shows in the editor.'
                                : 'Hidden from the editor. Your sentences are kept.',
                            style: const TextStyle(
                                color: PaperTheme.inkSoft, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _checkEnabled,
activeThumbColor: PaperTheme.inkSoft,
                      onChanged: _loaded ? _toggleCheck : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _sentenceCtrl,
                      onSubmitted: (_) => _add(),
                      minLines: 1,
                      maxLines: 3,
                      style: const TextStyle(
                          color: PaperTheme.ink, fontSize: 14),
                      decoration:
                          _field('Paste a sentence, e.g. If I had known…'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _categoryCtrl,
                      onSubmitted: (_) => _add(),
                      style: const TextStyle(
                          color: PaperTheme.ink, fontSize: 14),
                      decoration:
                          _field('Category, e.g. Conditionals'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _loaded ? _add : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: PaperTheme.inkSoft,
                      foregroundColor: PaperTheme.paper,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Add'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: !_loaded
                    ? const Center(
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2)))
                    : _items.isEmpty
                        ? const Center(
                            child: Text(
                              'No structures yet.\nAdd your first sentence above.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: PaperTheme.inkSoft,
                                  fontSize: 13,
                                  fontStyle:
                                      FontStyle.italic),
                            ),
                          )
                        : ListView(
                            children: [
                              for (final entry
                                  in _grouped().entries)
                                _CategorySection(
                                  name: entry.key,
                                  count: entry.value.length,
                                  onRename: entry.key == 'General'
                                      ? null
                                      : () =>
                                          _renameCategory(entry.key),
                                  onDelete: entry.key == 'General'
                                      ? null
                                      : () =>
                                          _deleteCategory(entry.key),
                                  children: [
                                    for (final item in entry.value)
                                      _SentenceRow(
                                        item: item,
                                        onToggle: (v) =>
                                            _toggle(item, v),
                                        onDelete: () =>
                                            _delete(item),
                                      ),
                                  ],
                                ),
                            ],
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  final String name;
  final int count;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final List<Widget> children;

  const _CategorySection({
    required this.name,
    required this.count,
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
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 0, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$name ($count)',
                  style: const TextStyle(
                      color: PaperTheme.inkSoft,
                      fontSize: 11,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w700),
                ),
              ),
              if (onRename != null)
                InkWell(
                  onTap: onRename,
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.edit_outlined,
                        size: 13, color: PaperTheme.inkSoft),
                  ),
                ),
              if (onDelete != null)
                InkWell(
                  onTap: onDelete,
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.delete_outline,
                        size: 14, color: PaperTheme.inkSoft),
                  ),
                ),
            ],
          ),
        ),
        ...children,
        const SizedBox(height: 6),
      ],
    );
  }
}

class _SentenceRow extends StatelessWidget {
  final GrammarItem item;
  final ValueChanged<bool?> onToggle;
  final VoidCallback onDelete;

  const _SentenceRow({
    required this.item,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFEFE8D6),
        border: Border.all(color: PaperTheme.lineThin),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: item.checked,
            activeColor: PaperTheme.inkSoft,
            onChanged: onToggle,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                item.text,
                style: const TextStyle(
                    color: PaperTheme.ink,
                    fontSize: 13,
                    height: 1.45),
              ),
            ),
          ),
          InkWell(
            onTap: onDelete,
            borderRadius: BorderRadius.circular(8),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.close,
                  size: 14, color: PaperTheme.inkSoft),
            ),
          ),
        ],
      ),
    );
  }
}
