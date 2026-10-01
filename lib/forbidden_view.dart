import 'package:flutter/material.dart';

import 'storage.dart';
import 'theme.dart';

/// Third page: the forbidden list. Words added here are struck through
/// automatically wherever they appear while writing.
class ForbiddenPage extends StatefulWidget {
  final StorageService storage;

  /// Shared live list (same object the writing view reads).
  final List<String> words;

  const ForbiddenPage({
    super.key,
    required this.storage,
    required this.words,
  });

  @override
  State<ForbiddenPage> createState() => _ForbiddenPageState();
}

class _ForbiddenPageState extends State<ForbiddenPage> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final raw = _ctrl.text.trim().toLowerCase();
    if (raw.isEmpty) return;
    if (!widget.words.contains(raw)) {
      setState(() {
        widget.words.add(raw);
        widget.words.sort();
      });
      await widget.storage.saveForbidden(widget.words);
    }
    _ctrl.clear();
  }

  Future<void> _remove(String word) async {
    setState(() => widget.words.remove(word));
    await widget.storage.saveForbidden(widget.words);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PaperTheme.paper,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Forbidden words',
                style: TextStyle(
                    color: PaperTheme.ink,
                    fontSize: 20,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'Any of these used while writing gets crossed with a line.',
                style: TextStyle(
                    color: PaperTheme.inkSoft, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('forbidden-add'),
                      controller: _ctrl,
                      onSubmitted: (_) => _add(),
                      style: const TextStyle(
                          color: PaperTheme.ink, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'add a word…',
                        hintStyle: const TextStyle(
                            color: PaperTheme.inkSoft,
                            fontSize: 13),
                        filled: true,
                        fillColor: const Color(0xFFEFE8D6),
                        contentPadding:
                            const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: PaperTheme.lineThin),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: PaperTheme.lineThin),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _add,
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
                child: widget.words.isEmpty
                    ? const Center(
                        child: Text(
                          'Nothing forbidden yet.',
                          style: TextStyle(
                              color: PaperTheme.inkSoft,
                              fontSize: 13,
                              fontStyle: FontStyle.italic),
                        ),
                      )
                    : ListView.builder(
                        itemCount: widget.words.length,
                        itemBuilder: (context, i) {
                          final w = widget.words[i];
                          return Container(
                            margin: const EdgeInsets.symmetric(
                                vertical: 3),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 9),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFE8D6),
                              border: Border.all(
                                  color: PaperTheme.lineThin),
                              borderRadius:
                                  BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.block,
                                    size: 15,
                                    color: PaperTheme.inkSoft),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    w,
                                    style: const TextStyle(
                                      color: PaperTheme.ink,
                                      fontSize: 14,
                                      decoration:
                                          TextDecoration.lineThrough,
                                    ),
                                  ),
                                ),
                                InkWell(
                                  onTap: () => _remove(w),
                                  borderRadius:
                                      BorderRadius.circular(8),
                                  child: const Padding(
                                    padding: EdgeInsets.all(4),
                                    child: Icon(Icons.close,
                                        size: 15,
                                        color: PaperTheme.inkSoft),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
