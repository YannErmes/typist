import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_graph_tool/graph_model.dart';
import 'package:word_graph_tool/graph_view.dart';
import 'package:word_graph_tool/main.dart';
import 'package:word_graph_tool/sheet_view.dart';
import 'package:word_graph_tool/storage.dart';
import 'package:word_graph_tool/tag_sheet.dart';

void main() {
  test('graph links multiple parents and children', () {
    final g = WordGraph();
    g.linkParentChild('meal', 'eat');
    g.linkParentChild('food', 'eat');
    g.linkParentChild('eat', 'orange');
    g.linkParentChild('eat', 'tomato');
    expect(g.parentsOf('eat').toSet(), {'meal', 'food'});
    expect(g.childrenOf('eat').toSet(), {'orange', 'tomato'});
  });

  test('word file round-trips parents, children and position', () {
    final node = WordNode('eat',
        parents: {'meal', 'food'},
        children: {'orange', 'tomato'},
        x: 123.4,
        y: 567.8);
    final text = StorageService.serializeWordFile(node);
    final back = StorageService.parseWordFile(text);
    expect(back, isNotNull);
    expect(back!.parents, {'meal', 'food'});
    expect(back.children, {'orange', 'tomato'});
    expect(back.x, closeTo(123.4, 0.01));
    expect(back.y, closeTo(567.8, 0.01));

    // Old files without coordinates still parse (auto-place).
    final legacy = StorageService.parseWordFile(
        '# eat\nparents: meal\nchildren: orange\n');
    expect(legacy, isNotNull);
    expect(legacy!.hasPos, isFalse);
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

  testWidgets('tag sheet opens on @word and closes cleanly',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    for (var i = 0;
        i < 60 && find.byType(EditableText).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    tester.state<SheetViewState>(find.byType(SheetView)).typeForTest('@eat');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TagGraphSheet), findsOneWidget);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TagGraphSheet), findsNothing);
    // Switch tabs back and forth over the live editor.
    await tester.tap(find.text('Graph'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Sheet'));
    await tester.pump(const Duration(milliseconds: 500));
    // Create a session, type, switch back to the first one.
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pump(const Duration(milliseconds: 500));
    tester
        .state<SheetViewState>(find.byType(SheetView))
        .typeForTest('second note body');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('First notes').first);
    await tester.pump(const Duration(milliseconds: 500));
    // Open/close the tag sheet for a few different tags.
    for (final tag in [' @meal', ' #meal', ' @eat']) {
      tester
          .state<SheetViewState>(find.byType(SheetView))
          .typeForTest(tag);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TagGraphSheet), findsOneWidget);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TagGraphSheet), findsNothing);
    }
  });

  testWidgets('tapping an arrow selects it and the chip deletes the link',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Graph'));
    await tester.pump(const Duration(milliseconds: 500));
    final state =
        tester.state<GraphViewState>(find.byType(GraphView).first);
    // Tap the meal->eat arrow midpoint first, before any selection
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

  testWidgets('app boots to sheet view', (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Word Graph Tool'), findsOneWidget);
  });
}
