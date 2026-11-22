import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:word_graph_tool/blast_demo.dart';
import 'package:word_graph_tool/blast_game.dart';
import 'package:word_graph_tool/blast_model.dart';
import 'package:word_graph_tool/blast_view.dart';
import 'package:word_graph_tool/graph_images.dart';
import 'package:word_graph_tool/graph_model.dart';
import 'package:word_graph_tool/graph_view.dart';
import 'package:word_graph_tool/storage.dart';

Future<void> wide(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump(const Duration(milliseconds: 100));
}

/// Mirrors the shell wiring: tapping a word in the real Graph page calls
/// BlastViewState.addPickedWord, exactly as HomeShell does.
class _PickerHarness extends StatefulWidget {
  final StorageService storage;
  final WordGraph graph;
  const _PickerHarness({required this.storage, required this.graph});

  @override
  State<_PickerHarness> createState() => _PickerHarnessState();
}

class _PickerHarnessState extends State<_PickerHarness> {
  final _blast = GlobalKey<BlastViewState>();

  BlastViewState get blast => _blast.currentState!;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: BlastView(
            key: _blast,
            storage: widget.storage,
            graph: widget.graph,
            onGraphChanged: () {},
            onRequestPick: () {},
          ),
        ),
        SizedBox(
          height: 320,
          child: GraphView(
            storage: widget.storage,
            graph: widget.graph,
            onGraphChanged: () {},
            pickerHint: 'Tap picture words',
            onSelectionChanged: (word) {
              if (word != null) _blast.currentState?.addPickedWord(word);
            },
          ),
        ),
      ],
    );
  }
}

void main() {
  test('blast bundles and their picture words round-trip', () {
    final bundle = BlastBundle(
      id: 'b1',
      title: 'Kitchen',
      items: const [
        BlastItem(word: 'house', image: 'images/house.jpg'),
        BlastItem(word: 'kitchen', image: 'https://example.com/kitchen.png'),
      ],
    );
    final back = BlastBundle.fromJson(bundle.toJson())!;
    expect(back.title, 'Kitchen');
    expect(back.items.length, 2);
    expect(back.items.first.word, 'house');
    expect(back.items.last.image, contains('https://'));
    expect(BlastItem.fromJson({'word': 'x'}), isNull);
  });

  test('blast bundles save and reload without init', () async {
    final s = StorageService();
    await s.saveBlastBundles([
      BlastBundle(
        id: 'b1',
        title: 'One',
        items: const [BlastItem(word: 'house', image: 'images/house.jpg')],
        createdAt: 1000,
      ),
    ]);
    final back = await s.loadBlastBundles();
    expect(back.single.title, 'One');
    expect(back.single.items.single.word, 'house');
  });

  test('demo bundles provide many named pictures, including two-part names',
      () {
    final demos = blastDemoBundles();
    expect(demos.length, 3);
    final items = demos.expand((b) => b.items).toList();
    expect(items.length, greaterThanOrEqualTo(30));
    expect(items.every((i) => i.image.startsWith('data:image/png;base64,')),
        isTrue);
    expect(items.map((i) => i.word), contains('blue square'));
    expect(items.map((i) => i.word), contains('ocean blue'));
    expect(demos.map((b) => b.id).toSet().length, 3);
  });

  testWidgets('Load demo bundles fills an empty library',
      (WidgetTester tester) async {
    await wide(tester);
    final storage = StorageService();
    final graph = WordGraph();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlastView(
            storage: storage,
            graph: graph,
            onGraphChanged: () {},
            onRequestPick: () {}),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Load demo bundles'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Shape shots'), findsNWidgets(2)); // rail + card
    expect(find.text('Pattern pack'), findsNWidgets(2));
    final saved = await storage.loadBlastBundles();
    expect(saved.length, 3);
    expect(saved.expand((b) => b.items).length, greaterThanOrEqualTo(30));
  });

  testWidgets('Pick from map adds words that have a picture',
      (WidgetTester tester) async {
    await wide(tester);
    final storage = StorageService();
    final graph = WordGraph();
    graph.connect('house', 'door');
    graph.get('house')!.image = 'images/house.jpg';
    graph.get('door')!.image = 'images/door.jpg';

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: _PickerHarness(storage: storage, graph: graph)),
    ));
    await tester.pump(const Duration(seconds: 2));
    final harness = tester.state<_PickerHarnessState>(
        find.byType(_PickerHarness));
    final view = harness.blast;

    await view.debugCreateBundle('House words', const []);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(find.text('Pick from map…'), findsOneWidget);

    // Tapping a word on the graph page adds it to the open bundle.
    final picker = tester.state<GraphViewState>(find.byType(GraphView));
    await picker.debugCreateWord('house', const Offset(300, 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(view.debugEditing!.items.length, 1);
    expect(view.debugEditing!.items.single.word, 'house');

    // A plain word with no picture must not join the bundle.
    await picker.debugCreateWord('plain', const Offset(320, 300));
    await tester.pump();
    expect(view.debugEditing!.items.length, 1);

    final saved = await storage.loadBlastBundles();
    expect(saved.single.items.single.word, 'house');
  });

  testWidgets('browser-picked mem pictures show and add in the picker',
      (WidgetTester tester) async {
    await wide(tester);
    // The 1x1 PNG a browser pick would have stored as a `mem:` ref.
    final bytes = Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=='));
    GraphImages.put('mem:picture1', bytes);

    final storage = StorageService();
    final graph = WordGraph();
    graph.ensure('doc').image = 'mem:picture1';

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: _PickerHarness(storage: storage, graph: graph)),
    ));
    await tester.pump(const Duration(seconds: 2));
    final view =
        tester.state<_PickerHarnessState>(find.byType(_PickerHarness)).blast;
    await view.debugCreateBundle('Web words', const []);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Edit'));
    await tester.pump();

    // The picture must render on the graph page that does the picking.
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
      findsOneWidget,
      reason: 'the mem picture should render on the map',
    );

    final picker = tester.state<GraphViewState>(find.byType(GraphView));
    await picker.debugCreateWord('doc', const Offset(300, 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(view.debugEditing!.items.length, 1);
    expect(view.debugEditing!.items.single.image, startsWith('data:image'));
  });

  testWidgets('browser file-pick data URLs render on the graph page',
      (WidgetTester tester) async {
    await wide(tester);
    final bytes = Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=='));
    final storage = StorageService();
    final graph = WordGraph();
    graph.ensure('kk').image = 'data:image/png;base64,${base64Encode(bytes)}';

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GraphView(
            storage: storage, graph: graph, onGraphChanged: () {}),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
      findsOneWidget,
      reason: 'a file-picked picture must show on the map, not a broken icon',
    );
  });

  testWidgets('two-part picture names can be typed and blasted',
      (WidgetTester tester) async {
    await wide(tester);
    final storage = StorageService();
    final graph = WordGraph();
    await storage.saveBlastBundles([
      BlastBundle(
        id: 'b2',
        title: 'Two-part',
        items: const [
          BlastItem(word: 'garbage disposal', image: 'images/gd.jpg'),
        ],
      ),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlastView(
            storage: storage,
            graph: graph,
            onGraphChanged: () {},
            onRequestPick: () {}),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Play'));
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final game = tester.state<BlastGameState>(find.byType(BlastGame));
    expect(game.debugChainLength, greaterThan(0));

    // The space between the two parts must be part of the typed word,
    // and a "p" in "disposal" must not be mistaken for the pause key.
    game.debugType('garbage disposal');
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(game.debugScore, greaterThan(0));
  });

  testWidgets('typing a picture word fires and scores',
      (WidgetTester tester) async {
    await wide(tester);
    final storage = StorageService();
    final graph = WordGraph();
    await storage.saveBlastBundles([
      BlastBundle(
        id: 'b1',
        title: 'Game',
        items: const [BlastItem(word: 'house', image: 'images/house.jpg')],
      ),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlastView(
            storage: storage,
            graph: graph,
            onGraphChanged: () {},
            onRequestPick: () {}),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Play'));
    // Drive real frames: a ticker needs many small steps, one big pump
    // only advances the game clock by a single (clamped) frame.
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final game = tester.state<BlastGameState>(find.byType(BlastGame));
    expect(game.debugRunning, isTrue);
    expect(find.text('SCORE'), findsOneWidget);
    expect(game.debugChainLength, greaterThan(0),
        reason: 'a picture ball must spawn before it can be typed');

    // Hovering shows a big preview in the empty side space.
    game.debugHover('house');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('PREVIEW'), findsOneWidget);
    // The preview must NOT reveal the word — that is what the player types.
    expect(find.text('house'), findsNothing);

    game.debugType('hous');
    expect(game.debugTyped, 'hous');
    // A wrong letter must be ignored, NOT wipe what was already typed.
    game.debugType('z');
    expect(game.debugTyped, 'hous',
        reason: 'a mistake should keep the typed prefix for correction');
    // Typing the right letter finishes the word.
    game.debugType('e');
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(game.debugScore, greaterThan(0));
  });

  test('each track shape draws a genuinely different path', () {
    final samples = <String>{};
    for (final shape in BlastShape.values) {
      final pts = debugBlastPath(shape, 2.35);
      final p = pts[(pts.length * 0.5).round()];
      samples.add('${p.dx.toStringAsFixed(0)},${p.dy.toStringAsFixed(0)}');
      expect(p.dx, greaterThanOrEqualTo(0),
          reason: '${shape.label} path should stay inside the board');
      expect(p.dx, lessThanOrEqualTo(400));
      expect(p.dy, greaterThanOrEqualTo(0));
      expect(p.dy, lessThanOrEqualTo(533));
    }
    expect(samples.length, greaterThanOrEqualTo(4),
        reason: 'shapes must not all draw the same curve');
  });

  test('blast track preferences round-trip', () async {
    final s = StorageService();
    final initial = await s.loadBlastTrack();
    expect(initial.turns, BlastTrack.defaultTurns);
    expect(initial.shape, BlastShape.spiral);

    await s.saveBlastTrack(const BlastTrack(
      turns: 3.2,
      shape: BlastShape.figure8,
    ));
    final back = await s.loadBlastTrack();
    expect(back.turns, 3.2);
    expect(back.shape, BlastShape.figure8);
    expect(BlastShape.fromId('flat'), BlastShape.oval); // old migration
    expect(BlastShape.values.length, 6);
  });

  testWidgets('track settings change spiral length and shape',
      (WidgetTester tester) async {
    await wide(tester);
    final storage = StorageService();
    final graph = WordGraph();
    await storage.saveBlastBundles([
      BlastBundle(
        id: 'b3',
        title: 'Track',
        items: const [BlastItem(word: 'house', image: 'images/h.jpg')],
      ),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlastView(
            storage: storage,
            graph: graph,
            onGraphChanged: () {},
            onRequestPick: () {}),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Play'));
    await tester.pump(const Duration(milliseconds: 300));

    final game = tester.state<BlastGameState>(find.byType(BlastGame));
    expect(game.debugTurns, BlastTrack.defaultTurns);
    expect(game.debugShape, BlastShape.spiral);

    await tester.tap(find.byTooltip('Track settings'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Track settings'), findsOneWidget);

    await tester.tap(find.text('Long'));
    await tester.pump();
    expect(game.debugTurns, 3.2);
    await tester.tap(find.text('Figure 8'));
    await tester.pump();
    expect(game.debugShape, BlastShape.figure8);

    await tester.tap(find.text('Done'));
    await tester.pump();
    final saved = await storage.loadBlastTrack();
    expect(saved.turns, 3.2);
    expect(saved.shape, BlastShape.figure8);
  });
}
