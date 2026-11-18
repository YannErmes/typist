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

void main() {
  test('flash bundle and sentence survive a JSON round-trip', () {
    final bundle = FlashBundle(
      id: 'fb-1',
      name: 'Smooth words',
      rootWord: 'smooth',
      words: const ['smooth', 'smoothie', 'syrup'],
      createdAt: 1000,
    );
    final back = FlashBundle.fromJson(bundle.toJson())!;
    expect(back.id, 'fb-1');
    expect(back.name, 'Smooth words');
    expect(back.words, ['smooth', 'smoothie', 'syrup']);
    expect(back.createdAt, 1000);

    final sentence = FlashSentence(
      id: 'fs-1',
      bundleId: 'fb-1',
      word: 'smooth',
      text: 'I like it smooth.',
      createdAt: 2000,
    );
    final sentenceBack = FlashSentence.fromJson(sentence.toJson())!;
    expect(sentenceBack.bundleId, 'fb-1');
    expect(sentenceBack.text, 'I like it smooth.');
    expect(
      FlashSentence.fromJson({'text': 'no word'}),
      isNull,
      reason: 'an incomplete saved sentence must never show up as a card',
    );
  });

  test('saving bundles never wipes sentences and vice versa', () async {
    final s = StorageService();
    await s.init();
    await s.saveFlashBundles([
      FlashBundle(
        id: 'fb-1',
        name: 'One',
        rootWord: 'alpha',
        words: const ['alpha', 'beta'],
        createdAt: 1000,
      ),
    ]);
    await s.saveFlashSentences([
      FlashSentence(
        id: 'fs-1',
        bundleId: 'fb-1',
        word: 'beta',
        text: 'sentence',
        createdAt: 2000,
      ),
    ]);
    final bundles = await s.loadFlashBundles();
    final sentences = await s.loadFlashSentences();
    expect(bundles.single.name, 'One');
    expect(sentences.single.text, 'sentence');

    await s.saveFlashBundles([
      ...bundles,
      FlashBundle(
        id: 'fb-2',
        name: 'Two',
        rootWord: 'gamma',
        words: const ['gamma'],
        createdAt: 3000,
      ),
    ]);
    expect((await s.loadFlashSentences()).length, 1);
    expect((await s.loadFlashBundles()).length, 2);
  });

  testWidgets('bundle takes every linked word; sentences live on the back',
      (WidgetTester tester) async {
    await wide(tester);
    final storage = StorageService(); // in-memory; no platform channel
    final graph = WordGraph();
    graph.connect('smooth', 'smoothie');
    graph.connect('smooth', 'smoothly');
    graph.connect('syrup', 'smooth'); // inbound link still counts
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FlashCardView(
          storage: storage,
          graph: graph,
          onGraphChanged: () {},
        ),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Flash cards'), findsOneWidget);

    await tester.enterText(byHint('type to filter the map'), 'smooth');
    await tester.pump();
    await tester.tap(find.byWidgetPredicate(
        (w) => w is Text && w.data == 'smooth')); // not the search field
    await tester.pump();
    await tester.enterText(byHint('e.g. smooth cards'), 'My bundle');
    await tester.pump();
    await tester.tap(find.text('Create bundle'));
    await tester.pump(const Duration(milliseconds: 500));

    final state =
        tester.state<FlashCardViewState>(find.byType(FlashCardView));
    expect(state.debugBundles.single.name, 'My bundle');
    expect(
      state.debugBundles.single.words,
      unorderedEquals(['smooth', 'smoothie', 'smoothly', 'syrup']),
    );
    expect(state.debugCurrentWord, 'smooth');
    expect(find.text('Card 1 of 4 · tap the card to flip'), findsOneWidget);

    await tester.enterText(
        byHint('Write a sentence with "smooth"…'), 'I like it smooth.');
    await tester.tap(find.text('Add sentence'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.debugSentences.length, 1);
    expect(find.text('I like it smooth.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3)); // snackbar clears
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(state.debugCurrentWord, isNot('smooth'));
    await tester.tap(find.text('Previous'));
    await tester.pump();
    expect(state.debugCurrentWord, 'smooth');

    await tester.tap(find.text('Flip'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('BACK · sentences for'), findsOneWidget);
    expect(find.text('I like it smooth.'), findsOneWidget);

    await tester.tap(find.text('All sentences'));
    await tester.pump();
    expect(find.text('I like it smooth.'), findsOneWidget);

    await tester.tap(find.text('Back to bundles'));
    await tester.pump();
    expect(find.text('Flash cards'), findsOneWidget);
    expect(find.textContaining('My bundle'), findsWidgets);
  });

  testWidgets('the same word keeps its history across overlapping bundles',
      (WidgetTester tester) async {
    await wide(tester);
    final storage = StorageService(); // in-memory; no platform channel
    final graph = WordGraph();
    graph.connect('alpha', 'beta');
    graph.connect('alpha', 'gamma');
    graph.connect('delta', 'beta');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FlashCardView(
          storage: storage,
          graph: graph,
          onGraphChanged: () {},
        ),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
    final state =
        tester.state<FlashCardViewState>(find.byType(FlashCardView));

    await state.debugCreateBundle('alpha', 'Bundle A');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Next')); // alpha -> beta
    await tester.pump();
    expect(state.debugCurrentWord, 'beta');
    await tester.enterText(
        byHint('Write a sentence with "beta"…'), 'from A');
    await tester.tap(find.text('Add sentence'));
    await tester.pump(const Duration(milliseconds: 500));

    await state.debugCreateBundle('delta', 'Bundle B');
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.debugCurrentWord, 'delta');
    await tester.tap(find.text('Next')); // delta -> beta
    await tester.pump();
    expect(state.debugCurrentWord, 'beta');
    // Flipping reads every sentence the word has, not just this bundle's.
    await tester.tap(find.text('Flip'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('from A'), findsOneWidget);
    expect(find.text('from B'), findsNothing);

    await tester.enterText(
        byHint('Write a sentence with "beta"…'), 'from B');
    await tester.tap(find.text('Add sentence'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('from B'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('All sentences'));
    await tester.pump();
    expect(find.text('from A'), findsNothing);
    expect(find.text('from B'), findsOneWidget);

    // Reopening bundle A shows only what was written in it.
    await tester.tap(find.text('Bundle A'));
    await tester.pump();
    await tester.tap(find.text('All sentences'));
    await tester.pump();
    expect(find.text('from A'), findsOneWidget);
    expect(find.text('from B'), findsNothing);
  });

  testWidgets('Graph page starts a named bundle on the Cards page',
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
    await tester.pump();
    expect(find.text('Name this bundle'), findsOneWidget);
    await tester.tap(find.text('Create'));
    await tester.pump(const Duration(milliseconds: 800));

    final flash =
        tester.state<FlashCardViewState>(find.byType(FlashCardView));
    expect(flash.debugBundles.length, 1);
    expect(flash.debugBundles.first.rootWord, 'eat');
    expect(flash.debugBundles.first.words.length, 4);
  });
}
