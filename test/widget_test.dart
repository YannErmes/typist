import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_graph_tool/graph_model.dart';
import 'package:word_graph_tool/graph_view.dart';
import 'package:word_graph_tool/main.dart';
import 'package:word_graph_tool/sheet_view.dart'
    show SheetView, SheetViewState, findGraphMatches;
import 'package:word_graph_tool/storage.dart';
import 'package:word_graph_tool/tag_sheet.dart';

void main() {
  test('graph connects, checks and cuts undirected links', () {
    final g = WordGraph();
    g.connect('meal', 'eat');
    g.connect('food', 'eat');
    g.connect('eat', 'orange');
    expect(g.neighborsOf('eat').toSet(), {'meal', 'food', 'orange'});
    expect(g.linked('eat', 'meal'), isTrue);
    expect(g.linked('meal', 'eat'), isTrue);
    g.disconnect('meal', 'eat');
    expect(g.linked('eat', 'meal'), isFalse);
    expect(g.neighborsOf('eat').toSet(), {'food', 'orange'});
  });

  test('graph matches are whole words, case-insensitive', () {
    const words = ['eat', 'meal', 'orange'];
    final hits = findGraphMatches(
        'I eat an EATERY with meal and ORANGE.', words);
    final texts = [
      for (final h in hits)
        'I eat an EATERY with meal and ORANGE.'.substring(h.$1, h.$2)
    ];
    expect(texts, ['eat', 'meal', 'ORANGE']);
    expect(findGraphMatches('nothing here', words), isEmpty);
    expect(findGraphMatches('', words), isEmpty);
    expect(findGraphMatches('eat eat', words), [(0, 3), (4, 7)]);
  });

  test('graph renames keeping links, position and color', () {
    final g = WordGraph();
    g.connect('eat', 'orange');
    final n = g.get('eat')!;
    n.x = 10;
    n.y = 20;
    n.color = 123;
    expect(g.rename('eat', 'dine'), isTrue);
    expect(g.get('eat'), isNull);
    expect(g.neighborsOf('dine'), ['orange']);
    expect(g.neighborsOf('orange'), ['dine']);
    expect(g.get('dine')!.x, 10);
    expect(g.get('dine')!.color, 123);
    expect(g.rename('dine', 'orange'), isFalse); // taken
  });

  test('word file round-trips links, position and color', () {
    final node = WordNode('eat',
        links: {'meal', 'orange'}, x: 123.4, y: 567.8, color: 4278190080);
    final text = StorageService.serializeWordFile(node);
    final back = StorageService.parseWordFile(text);
    expect(back, isNotNull);
    expect(back!.links, {'meal', 'orange'});
    expect(back.x, closeTo(123.4, 0.01));
    expect(back.y, closeTo(567.8, 0.01));
    expect(back.color, 4278190080);
  });

  test('legacy hierarchy files merge into plain links', () {
    final back = StorageService.parseWordFile(
        '# eat\nparents: meal, food\nchildren: orange\n');
    expect(back, isNotNull);
    expect(back!.links, {'meal', 'food', 'orange'});
  });

  test('sessions save, list and reload content', () async {
    final s = StorageService();
    await s.init(); // falls back to in-memory when no folder exists
    final a = await s.createSession('Alpha');
    await s.saveSession(
        a.id, 'Alpha', jsonEncode(const <Object>[{'insert': 'hello\n'}]));
    final list = await s.loadSessions();
    expect(list.any((e) => e.id == a.id && e.title == 'Alpha'), isTrue);
    expect(await s.loadSessionDelta(a.id), contains('hello'));
    await s.deleteSession(a.id);
    expect(await s.loadSessionDelta(a.id), isNull);
  });

  testWidgets('@ mention inserts the word and pops its map',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    for (var i = 0;
        i < 60 && find.byType(EditableText).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final sheetState =
        tester.state<SheetViewState>(find.byType(SheetView));
    sheetState.typeForTest('I like @or');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('orange'), findsOneWidget);
    await tester.tap(find.text('orange'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(sheetState.debugPlainText(), contains('orange '));
    expect(sheetState.debugPlainText(), isNot(contains('@or')));
    // The map slides up already on the mentioned word.
    expect(find.byType(TagGraphSheet), findsOneWidget);
    expect(find.text('"orange" on the map'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TagGraphSheet), findsNothing);
  });

  testWidgets('graph words turn green while writing',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    for (var i = 0;
        i < 60 && find.byType(EditableText).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final sheetState =
        tester.state<SheetViewState>(find.byType(SheetView));
    sheetState.typeForTest('I love orange juice');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(sheetState.debugDeltaJson(), contains('f69697'));
    // Editing it away lifts the green again.
    sheetState.typeForTest(' and more');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(sheetState.debugDeltaJson(), contains('f69697'));
  });

  testWidgets('tapping a link selects it and the chip deletes it',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Graph'));
    await tester.pump(const Duration(milliseconds: 500));
    final state =
        tester.state<GraphViewState>(find.byType(GraphView).first);
    // Tap the meal-eat link midpoint first, before any selection
    // moves the canvas (inspector bar would shift everything down).
    final mid = state.debugEdgeMid('meal', 'eat');
    expect(mid, isNotNull);
    await tester.tapAt(state.debugToGlobal(mid!));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Delete this link?'), findsOneWidget);
    await tester.tap(find.text('Delete this link?'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Delete this link?'), findsNothing);
    expect(state.debugEdgeMid('meal', 'eat'), isNull);
  });

  testWidgets('dragged word stays exactly where dropped',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Graph'));
    await tester.pump(const Duration(milliseconds: 500));
    final state =
        tester.state<GraphViewState>(find.byType(GraphView).first);
    final start = state.debugCenter('meal')!;
    final gesture =
        await tester.startGesture(state.debugToGlobal(start));
    await gesture.moveBy(const Offset(40, 20));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(40, 20));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(40, 20));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    final end = state.debugCenter('meal')!;
    expect(end.dx, closeTo(start.dx + 120, 2.0));
    expect(end.dy, closeTo(start.dy + 60, 2.0));
    final node = state.widget.graph.get('meal')!;
    expect(node.x, closeTo(end.dx, 0.5));
    expect(node.y, closeTo(end.dy, 0.5));
  });

  testWidgets('double-tap dialog creates a word without freezing',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Graph'));
    await tester.pump(const Duration(milliseconds: 500));
    final state =
        tester.state<GraphViewState>(find.byType(GraphView).first);
    // Empty on-screen canvas between the first two bubbles.
    final at = state.debugToGlobal(const Offset(435, 260));
    final g1 = await tester.startGesture(at);
    await g1.up();
    await tester.pump(const Duration(milliseconds: 60));
    final g2 = await tester.startGesture(at);
    await g2.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('New word'), findsOneWidget);
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(EditableText),
    );
    expect(dialogField, findsOneWidget);
    await tester.tap(dialogField);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(dialogField, 'yann');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Create'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('New word'), findsNothing);
    expect(find.text('yann'), findsWidgets);
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('rail search filters without creating; pick scrolls to word',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Graph'));
    await tester.pump(const Duration(milliseconds: 500));
    final state =
        tester.state<GraphViewState>(find.byType(GraphView).first);
    final search = find.byKey(const ValueKey('graph-search'));
    // Unknown word: offered for creation, never auto-created.
    await tester.enterText(search, 'zzz');
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.widget.graph.get('zzz'), isNull);
    expect(find.text('+ Create "zzz"'), findsOneWidget);
    await tester.tap(find.text('+ Create "zzz"'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.widget.graph.get('zzz'), isNotNull);
    // Existing word: pick the match to select it.
    await tester.enterText(search, 'eat');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('eat').first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('app boots to sheet view', (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Word Graph Tool'), findsOneWidget);
  });
}
