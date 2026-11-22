import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_graph_tool/flashcard_model.dart';
import 'package:word_graph_tool/flashcard_view.dart';
import 'package:word_graph_tool/graph_model.dart';
import 'package:word_graph_tool/graph_view.dart';
import 'package:word_graph_tool/main.dart';
import 'package:word_graph_tool/storage.dart';

Finder byHint(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
    );

Future<void> wide(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump(const Duration(milliseconds: 100));
}

Widget _view(StorageService storage, WordGraph graph,
        {VoidCallback? onPick}) =>
    MaterialApp(
      home: Scaffold(
        body: FlashCardView(
          storage: storage,
          graph: graph,
          onGraphChanged: () {},
          onRequestPick: onPick ?? () {},
        ),
      ),
    );

void main() {
  test('card survives a JSON round-trip with blocked answers', () {
    final card = FlashCard(
      id: 'fc-1',
      scenario: 'At a restaurant',
      question: 'How do you ask for the bill?',
      target: 'check',
      blocked: ['bill', 'receipt'],
      goodCount: 3,
      lastGoodAt: 1000,
      nextReview: 2000,
    );
    final back = FlashCard.fromJson(card.toJson())!;
    expect(back.id, 'fc-1');
    expect(back.scenario, 'At a restaurant');
    expect(back.question, 'How do you ask for the bill?');
    expect(back.target, 'check');
    expect(back.blocked, ['bill', 'receipt']);
    expect(back.goodCount, 3);
    expect(back.lastGoodAt, 1000);
    expect(back.nextReview, 2000);
    expect(FlashCard.fromJson({'scenario': 'no target'}), isNull);
  });

  test('legacy bundles migrate to cards and keep blocked answers', () async {
    final s = StorageService();
    await s.saveFlashBundles([
      FlashBundle(
        id: 'fb-1',
        name: 'Smooth words',
        rootWord: 'smooth',
        words: const ['smooth', 'smoothie'],
        createdAt: 1000,
      ),
      FlashBundle(
        id: 'fb-2',
        name: 'More',
        rootWord: 'smoothie',
        words: const ['smoothie', 'syrup'],
        createdAt: 2000,
      ),
    ]);

    final migrated = await s.loadFlashCards();
    expect(migrated.length, 3);
    expect(migrated.map((c) => c.target),
        unorderedEquals(['smooth', 'smoothie', 'syrup']));
    expect(migrated.every((c) => c.scenario.isEmpty && c.question.isEmpty),
        isTrue);
    expect(migrated.every((c) => c.goodCount == 0), isTrue);

    // Blocked answers persist across loads and never get cleared.
    migrated.first.blocked.add('silky');
    await s.saveFlashCards(migrated);
    final again = await s.loadFlashCards();
    expect(again.first.blocked, ['silky']);
    expect((await s.loadFlashBundles()).length, 2,
        reason: 'old data is left intact');
  });

  testWidgets('create a card, then block up to the reveal and answer',
      (WidgetTester tester) async {
    await wide(tester);
    final storage = StorageService();
    final graph = WordGraph();
    await tester.pumpWidget(_view(storage, graph));
    await tester.pump(const Duration(seconds: 2));
    final state =
        tester.state<FlashCardViewState>(find.byType(FlashCardView));

    await tester.tap(find.text('Add new card'));
    await tester.pump();
    await tester.enterText(
        byHint('e.g. garbage disposal'), 'garbage disposal');
    await tester.enterText(byHint('Describe a situation…'), 'In the kitchen');
    await tester.enterText(byHint('What would you ask in that situation?'),
        'What do you call this?');
    await tester.tap(find.text('Save card'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.debugCards.length, 1);

    await tester.tap(find.text('garbage disposal').first);
    await tester.pump();
    expect(find.text('In the kitchen'), findsOneWidget);
    expect(find.text('What do you call this?'), findsOneWidget);
    expect(find.textContaining('TARGET REVEALED'), findsNothing);
    expect(state.debugStage, 'answering');

    // Five blocked attempts in this session.
    for (var i = 0; i < kRevealAfterBlocks; i++) {
      await tester.enterText(byHint('Answer in your own words…'), 'bin$i');
      await tester.tap(find.text('Check'));
      await tester.pump();
      expect(find.textContaining('defaults eliminated'), findsNWidgets(2));
      await tester.tap(find.text('Block'));
      await tester.pump();
    }
    expect(state.debugAttempts, kRevealAfterBlocks);
    expect(state.debugStage, 'revealed');
    expect(find.textContaining('TARGET REVEALED'), findsOneWidget);
    expect(find.text('garbage disposal'), findsWidgets);

    final blocked = state.debugActive!.blocked;
    expect(blocked.length, kRevealAfterBlocks);
    expect(blocked.contains('bin0'), isTrue);

    // Good answer: the text is discarded, only counters change.
    await tester.enterText(
        byHint('Use "garbage disposal" in your answer…'),
        'It is a garbage disposal.');
    await tester.tap(find.text('Good'));
    await tester.pump(const Duration(milliseconds: 300));
    final saved = await storage.loadFlashCards();
    expect(saved.single.goodCount, 1);
    expect(saved.single.lastGoodAt, isNotNull);
    expect(saved.single.blocked.length, kRevealAfterBlocks);
    expect(saved.single.blocked.contains('It is a garbage disposal.'),
        isFalse);
    expect(state.debugAttempts, 0);
  });

  testWidgets('blocked list persists and duplicate answers are ignored',
      (WidgetTester tester) async {
    await wide(tester);
    final storage = StorageService();
    final graph = WordGraph();
    await tester.pumpWidget(_view(storage, graph));
    await tester.pump(const Duration(seconds: 2));
    final state =
        tester.state<FlashCardViewState>(find.byType(FlashCardView));

    await state.debugAddCard(FlashCard(id: 'c1', target: 'smooth'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('smooth').first);
    await tester.pump();

    await tester.enterText(byHint('Answer in your own words…'), 'silky');
    await tester.tap(find.text('Check'));
    await tester.pump();
    await tester.tap(find.text('Block'));
    await tester.pump();

    // Same answer again — no exact duplicate.
    await tester.enterText(byHint('Answer in your own words…'), 'silky');
    await tester.tap(find.text('Check'));
    await tester.pump();
    await tester.tap(find.text('Block'));
    await tester.pump();
    expect(state.debugActive!.blocked, ['silky']);

    // A single blocked answer can be removed from the checking view.
    await tester.enterText(byHint('Answer in your own words…'), 'another');
    await tester.tap(find.text('Check'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pump();
    expect(state.debugActive!.blocked, isEmpty);
  });

  testWidgets('graph Make flash cards opens an editor with the target set',
      (WidgetTester tester) async {
    await wide(tester);
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));

    await tester.tap(find.text('Graph'));
    await tester.pump(const Duration(milliseconds: 800));
    final graphState =
        tester.state<GraphViewState>(find.byType(GraphView));
    await graphState.debugCreateWord('eat', const Offset(320, 300));
    await tester.pump();

    await tester.tap(find.byTooltip('Make flash cards'));
    await tester.pump(const Duration(milliseconds: 800));
    final flash =
        tester.state<FlashCardViewState>(find.byType(FlashCardView));
    expect(flash.debugTargetText, 'eat');
    expect(find.text('Pick from graph'), findsOneWidget);
    expect(find.text('Scenario'), findsOneWidget);
    expect(find.text('Question'), findsOneWidget);
  });
}
