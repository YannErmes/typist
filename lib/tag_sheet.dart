import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'graph_model.dart';
import 'graph_view.dart';
import 'storage.dart';
import 'theme.dart';

/// Bottom sheet that slides up while writing: the full mind-map,
/// focused on the tagged word, with copy right there.
///
/// [focus] is a live notifier — when the tag in the sheet changes to
/// another exact word, the map refocuses without reopening.
class TagGraphSheet extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  final String mode; // '@' or '#'
  final ValueNotifier<String> focus;
  final VoidCallback onGraphChanged;

  const TagGraphSheet({
    super.key,
    required this.storage,
    required this.graph,
    required this.mode,
    required this.focus,
    required this.onGraphChanged,
  });

  @override
  State<TagGraphSheet> createState() => _TagGraphSheetState();
}

class _TagGraphSheetState extends State<TagGraphSheet> {
  late String _focus = widget.focus.value;
  String? _picked;
  String? _notice;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_onFocus);
  }

  void _onFocus() {
    setState(() {
      _focus = widget.focus.value;
      _picked = null;
      _notice = null;
    });
  }

  @override
  void dispose() {
    widget.focus.removeListener(_onFocus);
    super.dispose();
  }

  void _copy(String word) {
    Clipboard.setData(ClipboardData(text: word));
    setState(() => _notice = 'Copied "$word" — ready to paste.');
  }

  @override
  Widget build(BuildContext context) {
    final current = _picked ?? _focus;
    final title =
        widget.mode == '@' ? 'under "@$current"' : 'above "#$current"';
    return Container(
      decoration: const BoxDecoration(
        color: PaperTheme.paper,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
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
          Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: PaperTheme.inkSoft,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _copy(current),
                  icon: const Icon(Icons.copy,
                      size: 15, color: PaperTheme.ink),
                  label: Text('Copy "$current"',
                      style: const TextStyle(
                          color: PaperTheme.ink, fontSize: 13)),
                ),
                IconButton(
                  tooltip: 'Back to writing',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.keyboard_arrow_down,
                      color: PaperTheme.inkSoft),
                ),
              ],
            ),
          ),
          if (_notice != null)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Text(
                _notice!,
                style: const TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 11),
              ),
            ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(18)),
              child: GraphView(
                key: ValueKey(_focus),
                storage: widget.storage,
                graph: widget.graph,
                initialWord: _focus,
                onSelectionChanged: (s) => setState(() {
                  _picked = s;
                  _notice = null;
                }),
                onGraphChanged: widget.onGraphChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
