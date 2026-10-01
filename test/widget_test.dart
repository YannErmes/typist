import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_graph_tool/graph_model.dart';
import 'package:word_graph_tool/graph_view.dart';
import 'package:word_graph_tool/main.dart';
import 'package:word_graph_tool/sheet_view.dart'
    show SheetView, SheetViewState, countWords, findGraphMatches;
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
    expect(
        hits.map((h) => (h.start, h.end, h.word)).toList(),
        [(0 + 2, 0 + 5, 'eat'), (21, 25, 'meal'), (30, 36, 'ORANGE'.toLowerCase())]);
    expect(findGraphMatches('nothing here', words), isEmpty);
    expect(findGraphMatches('', words), isEmpty);
    expect(
        findGraphMatches('eat eat', words)
            .map((h) => (h.start, h.end))
            .toList(),
        [(0, 3), (4, 7)]);
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

  test('word file round-trips multi-line meaning', () {
    final node = WordNode('eat', meaning: 'A sweet fruit.\nGrows on trees.');
    final back =
        StorageService.parseWordFile(StorageService.serializeWordFile(node));
    expect(back, isNotNull);
    expect(back!.meaning, 'A sweet fruit.\nGrows on trees.');
    final plain =
        StorageService.parseWordFile('# eat\nlinks: orange\n');
    expect(plain, isNotNull);
    expect(plain!.meaning, isNull);
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

  test('forbidden words save normalized and reload', () async {
    final s = StorageService();
    await s.init(); // falls back to in-memory when no folder exists
    await s.saveForbidden(['  Darn ', 'darn', '', 'heck']);
    expect(await s.loadForbidden(), ['darn', 'heck']);
  });

  test('legacy hierarchy files merge into plain links', () {
    final back = StorageService.parseWordFile(
        '# eat\nparents: meal, food\nchildren: orange\n');
    expect(back, isNotNull);
    expect(back!.links, {'meal', 'food', 'orange'});
  });

  test('word counts ignore extra whitespace', () {
    expect(countWords(''), 0);
    expect(countWords('   \n '), 0);
    expect(countWords('hello world'), 2);
    expect(countWords('  one   two\nthree  '), 3);
    expect(countWords("don't stop"), 2);
  });

  test('sessions round-trip their folder', () async {
    final s = StorageService();
    await s.init(); // falls back to in-memory when no folder exists
    final a = await s.createSession('Alpha', folder: 'Work');
    await s.saveSession(a.id, 'Alpha', '[]', folder: 'Work');
    final list = await s.loadSessions();
    final back = list.firstWhere((e) => e.id == a.id);
    expect(back.folder, 'Work');
    // Missing folder migrates to Notes.
    final b = await s.createSession('Beta');
    await s.saveSession(b.id, 'Beta', '[]');
    expect(
        (await s.loadSessions()).firstWhere((e) => e.id == b.id).folder,
        'Notes');
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

  testWidgets('graph words glow their card color while writing',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    for (var i = 0;
        i < 60 && find.byType(EditableText).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final sheetState =
        tester.state<SheetViewState>(find.byType(SheetView));
    // No card color yet: neutral default fill.
    sheetState.typeForTest('I love orange juice');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(sheetState.debugDeltaJson(), contains('d9cfb0'));
    // Give orange a card color: the text follows it.
    sheetState.widget.graph.get('orange')!.color = 0xFFE8A0A0;
    sheetState.refreshGraph();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(sheetState.debugDeltaJson(), contains('e8a0a0'));
  });

  testWidgets('#word chooser bans or maps, #[phrase] bans',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    for (var i = 0;
        i < 60 && find.byType(EditableText).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final sheetState =
        tester.state<SheetViewState>(find.byType(SheetView));
    // Typing #word offers both destinations; nothing auto-fires.
    sheetState.typeForTest('this is #yuck');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Ban "yuck"'), findsOneWidget);
    expect(find.text('Map "yuck"'), findsOneWidget);
    expect(sheetState.widget.forbidden, isNot(contains('yuck')));
    expect(sheetState.widget.graph.get('yuck'), isNull);
    // Choose ban.
    await tester.tap(find.text('Ban "yuck"'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(sheetState.widget.forbidden, contains('yuck'));
    expect(sheetState.debugDeltaJson(), contains('"strike":true'));
    // Choose map for another word.
    sheetState.typeForTest(' plus #pear');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Map "pear"'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(sheetState.widget.graph.get('pear'), isNotNull);
    expect(find.byType(TagGraphSheet), findsOneWidget);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TagGraphSheet), findsNothing);
    // #[phrase] still bans the whole phrase on ].
    sheetState.typeForTest('#[very bad phrase] ');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
        sheetState.widget.forbidden, contains('very bad phrase'));
  });

  testWidgets('word count follows the typed text',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    for (var i = 0;
        i < 60 && find.byType(EditableText).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    tester
        .state<SheetViewState>(find.byType(SheetView))
        .typeForTest('one two three');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('3 words'), findsOneWidget);
  });

  testWidgets('folders group notes and accept moves',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    for (var i = 0;
        i < 60 && find.byType(EditableText).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    // New folder via dialog.
    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await tester.pump(const Duration(milliseconds: 500));
    final folderField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(folderField, findsOneWidget);
    await tester.tap(folderField);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(folderField, 'Work');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Work (0)'), findsOneWidget);
    // Move the open note into it.
    await tester.tap(find.byIcon(Icons.drive_file_move_outlined).first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Work'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Work (1)'), findsOneWidget);
  });

  testWidgets('forbidden words get struck through while writing',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    for (var i = 0;
        i < 60 && find.byType(EditableText).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    // Ban a word, then use it while writing.
    await tester.tap(find.text('Banned'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(
        find.byKey(const ValueKey('forbidden-add')), 'darn');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Add'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('darn'), findsWidgets);
    await tester.tap(find.text('Sheet'));
    await tester.pump(const Duration(milliseconds: 500));
    tester
        .state<SheetViewState>(find.byType(SheetView))
        .typeForTest('oh darn it');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    final sheetState =
        tester.state<SheetViewState>(find.byType(SheetView));
    expect(sheetState.debugDeltaJson(), contains('"strike":true'));
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
    // Inspector open for the picked word (rename + meaning edit icons).
    expect(find.byIcon(Icons.edit_outlined), findsWidgets);
  });

  testWidgets('app boots to sheet view', (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Word Graph Tool'), findsOneWidget);
  });
}
