import 'dart:convert';

import 'storage.dart';

/// A flagged passage: an exact quote plus the reference structure id.
typedef GrammarFlag = ({String quote, String id});

/// Builds the grammar-spot request. Only [checked] reference sentences
/// are included, grouped under their categories. The model must report
/// matches by id and must never rewrite or suggest rephrasings.
String buildGrammarPrompt(String text, List<GrammarItem> checked) {
  final buf = StringBuffer()
    ..writeln(
        'You are a grammar spotter inside a note-taking app. I will give '
        'you REFERENCE STRUCTURES (each has an id, a category, and an '
        'example sentence) and then MY TEXT.')
    ..writeln()
    ..writeln('REFERENCE STRUCTURES:');
  for (var i = 0; i < checked.length; i++) {
    final id = 'S${i + 1}';
    buf.writeln('[$id] (${checked[i].category}) ${checked[i].text}');
  }
  buf
    ..writeln()
    ..writeln('MY TEXT:')
    ..writeln(text.trim().isEmpty ? '(empty)' : text.trim())
    ..writeln()
    ..writeln('TASK: find passages in MY TEXT where one of the reference '
        'structures could be used FOR GRAMMAR ACCURACY (not for meaning).')
    ..writeln('RULES:')
    ..writeln('- Do NOT rewrite anything.')
    ..writeln('- Do NOT suggest rephrasings or alternative wording.')
    ..writeln('- Never change or comment on meaning, only grammar fit.')
    ..writeln('- Reply ONLY with a JSON array, no other text.')
    ..writeln('- Each entry: {"quote": "<exact substring copied '
        'character-for-character from MY TEXT>", "structure": "<id>"}')
    ..writeln('- "quote" must be an EXACT substring of MY TEXT (3 to 15 '
        'words). Never invent text.')
    ..writeln('- "structure" is the id (like S2) of the single '
        'best-matching reference.')
    ..writeln('- One entry per passage; at most 12 entries.')
    ..writeln('- If nothing matches, reply with exactly: []');
  return buf.toString();
}

/// Best-effort parse of the model's reply into flags. Returns [] when
/// there is nothing usable (including an explicit empty array).
List<GrammarFlag> parseGrammarFlags(String body) {
  final out = <GrammarFlag>[];
  void addMap(Map<dynamic, dynamic> map) {
    final quote = (map['quote'] ?? '').toString();
    final id = (map['structure'] ?? '').toString().trim();
    if (quote.trim().isEmpty || id.isEmpty) return;
    if (out.length >= 12) return;
    out.add((quote: quote, id: id));
  }

  try {
    final start = body.indexOf('[');
    final end = body.lastIndexOf(']');
    if (start >= 0 && end > start) {
      final decoded = jsonDecode(body.substring(start, end + 1));
      if (decoded is List) {
        for (final e in decoded) {
          if (e is Map) addMap(e);
        }
        if (out.isNotEmpty) return out;
      }
    }
  } catch (_) {}
  // Fallback: fish flat {...} objects out of chatter.
  try {
    for (final m in RegExp(r'\{[^{}]*\}').allMatches(body)) {
      final decoded = jsonDecode(m.group(0)!);
      if (decoded is Map) addMap(decoded);
      if (out.length >= 12) break;
    }
  } catch (_) {}
  return out;
}

/// Resolves a flag's structure id back to its sentence + category.
({String sentence, String category})? resolveGrammarFlag(
    GrammarFlag flag, List<GrammarItem> checked) {
  final m = RegExp(r'^S(\d+)$').firstMatch(flag.id.trim());
  if (m == null) return null;
  final i = int.tryParse(m.group(1)!);
  if (i == null || i < 1 || i > checked.length) return null;
  final item = checked[i - 1];
  return (sentence: item.text, category: item.category);
}
