import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'graph_model.dart';
import 'graph_view.dart';
import 'storage.dart';
import 'theme.dart';

/// Bottom sheet that slides up from a mention: the mind-map,
/// opened already scrolled to the mentioned word, with copy at hand.
class TagGraphSheet extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  final String word;
  final VoidCallback onGraphChanged;

  const TagGraphSheet({
    super.key,
    required this.storage,
    required this.graph,
    required this.word,
    required this.onGraphChanged,
  });

  @override
  State<TagGraphSheet> createState() => _TagGraphSheetState();
}

class _TagGraphSheetState extends State<TagGraphSheet> {
  String? _picked;
  String? _notice;

  void _copy(String word) {
    Clipboard.setData(ClipboardData(text: word));
    setState(() => _notice = 'Copied "$word" — ready to paste.');
  }

  @override
  Widget build(BuildContext context) {
    final current = _picked ?? widget.word;
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
                    '"$current" on the map',
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
                key: ValueKey(widget.word),
                storage: widget.storage,
                graph: widget.graph,
                initialWord: widget.word,
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
