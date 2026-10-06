import 'graph_model.dart';

/// Human rhythm label for an interval in minutes.
String intervalText(int minutes) {
  if (minutes <= 1) return 'every minute';
  if (minutes < 60) return 'every $minutes minutes';
  if (minutes == 60) return 'every hour';
  if (minutes < 1440) {
    final h = minutes ~/ 60;
    return h == 1 ? 'every hour' : 'every $h hours';
  }
  final d = minutes ~/ 1440;
  return d == 1 ? 'every day' : 'every $d days';
}

/// Countdown label for a due timestamp against now.
String dueText(int dueAt, int now) {
  final diff = dueAt - now;
  if (diff <= 0) {
    final over = -diff;
    if (over < 60000) return 'due now';
    if (over < 3600000) {
      final m = (over / 60000).round();
      return m <= 1 ? 'overdue by a minute' : 'overdue by $m min';
    }
    if (over < 86400000) {
      final h = (over / 3600000).round();
      return h <= 1 ? 'overdue by an hour' : 'overdue by $h h';
    }
    final d = (over / 86400000).round();
    return d <= 1 ? 'overdue by a day' : 'overdue by $d d';
  }
  if (diff < 60000) return 'due any second';
  if (diff < 3600000) {
    final m = (diff / 60000).round();
    return m <= 1 ? 'due in a minute' : 'due in $m min';
  }
  if (diff < 86400000) {
    final h = (diff / 3600000).round();
    return h <= 1 ? 'due in an hour' : 'due in $h h';
  }
  final d = (diff / 86400000).round();
  return d <= 1 ? 'due in a day' : 'due in $d d';
}

/// Practice bundle: the word plus everything directly linked to it.
/// Computed live so it always mirrors the current map.
List<String> bundleFor(WordGraph graph, String word) {
  final key = WordGraph.norm(word);
  if (graph.get(key) == null) return const [];
  final out = <String>[key];
  for (final n in graph.neighborsOf(key)) {
    if (n != key && !out.contains(n)) out.add(n);
  }
  return out;
}

/// Bundle words already used (whole-word, case-insensitive) in the text.
Set<String> usedWords(String text, List<String> words) {
  return {for (final m in findGraphMatches(text, words)) m.word};
}
