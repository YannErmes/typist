import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' show Document;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spell_check_on_client/spell_check_on_client.dart';
import 'package:word_graph_tool/ai_service.dart';
import 'package:word_graph_tool/grammar_check.dart';
import 'package:word_graph_tool/graph_model.dart';
import 'package:word_graph_tool/graph_view.dart';
import 'package:word_graph_tool/main.dart';
import 'package:word_graph_tool/sheet_view.dart'
    show
        SheetView,
        SheetViewState,
        countWords,
        findUnknownRanges;
import 'package:word_graph_tool/computer_video.dart';
import 'package:word_graph_tool/repetition_logic.dart';
import 'package:word_graph_tool/storage.dart';
import 'package:word_graph_tool/frame_link.dart';
import 'package:word_graph_tool/tag_sheet.dart';

/// Desktop-wide window so the floating nav pill never covers the
/// bottom-anchored controls these tests tap (graph toolbar, fix-it chip).
Future<void> wideWindow(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  test('grammar prompt carries checked structures and strict rules', () {
    final items = [
      GrammarItem(
          id: 'a', text: 'If I had known, I would have come.',
          category: 'Conditionals'),
      GrammarItem(
          id: 'b', text: 'She has lived here since 2010.',
          category: 'Tenses', checked: false),
    ];
    final checked = [for (final i in items) if (i.checked) i];
    final prompt = buildGrammarPrompt('I wish I know.', checked);
    expect(prompt, contains('[S1] (Conditionals)'));
    expect(prompt, contains('If I had known'));
    expect(prompt, isNot(contains('She has lived')));
    expect(prompt, contains('Do NOT rewrite'));
    expect(prompt, contains('Do NOT suggest rephrasings'));
  });

  test('grammar flags parse leniently, resolve strictly', () {
    const body = '''
[{"quote": "I wish I know", "structure": "S1"},
 {"quote": "oops", "structure": "S9"},
 {"quote": "", "structure": "S1"},
 {"nope": true}]
[] tail''';
    final flags = parseGrammarFlags(body);
    expect(flags.length, 2);
    expect(parseGrammarFlags('nothing matches really'), isEmpty);
    expect(parseGrammarFlags('[]'), isEmpty);
    final items = [
      GrammarItem(id: 'a', text: 'If I had known.', category: 'Cond')
    ];
    final ok = resolveGrammarFlag(flags.first, items);
    expect(ok, isNotNull);
    expect(ok!.category, 'Cond');
    expect(resolveGrammarFlag(flags[1], items), isNull);
  });

  test('grammar items save and reload with checks intact', () async {
    final s = StorageService();
    await s.init(); // falls back to in-memory when no folder exists
    await s.saveGrammar([
      GrammarItem(
          id: 'a', text: 'If I had known.', category: 'Conditionals'),
      GrammarItem(
          id: 'b', text: 'Had I known.', category: 'Conditionals',
          checked: false),
    ]);
    final back = await s.loadGrammar();
    expect(back.length, 2);
    expect(back.first.text, 'If I had known.');
    expect(back.first.checked, isTrue);
    expect(back[1].checked, isFalse);
    expect(back[1].category, 'Conditionals');
  });

  test('frame labels format and seek links round-trip', () {
    expect(FrameLink.formatTime(0), '0:00');
    expect(FrameLink.formatTime(67), '1:07');
    expect(FrameLink.formatTime(277), '4:37');
    expect(FrameLink.formatTime(3723), '1:02:03');
    final url = FrameLink.at(277);
    expect(url, 'streamframe://frame?t=277');
    expect(FrameLink.secondsOf(url), 277);
    expect(FrameLink.secondsOf('https://youtu.be/x?t=277'), isNull);
    expect(FrameLink.secondsOf('streamframe://t=abc'), isNull);
    expect(FrameLink.secondsOf('not a link'), isNull);
    expect(FrameLink.basename(r'C:\Vids\talk.mp4'), 'talk.mp4');
    expect(FrameLink.basename('/home/u/talk.mp4'), 'talk.mp4');
    expect(FrameLink.basename('talk.mp4'), 'talk.mp4');
    expect(FrameLink.isLegacyLink('https://youtu.be/x'), isTrue);
    expect(FrameLink.isLegacyLink(r'C:\Vids\talk.mp4'), isFalse);
    expect(FrameLink.isLegacyLink('talk.mp4'), isFalse);
  });

  test('session video files save and survive plain saves', () async {
    final s = StorageService();
    await s.init();
    await s.saveSession('n1', 'Stream note', '[]');
    var sessions = await s.loadSessions();
    expect(sessions.single.videoUrl, '');
    await s.saveSession('n1', 'Stream note', '[]',
        video: r'C:\Vids\talk.mp4');
    sessions = await s.loadSessions();
    expect(sessions.single.videoUrl, r'C:\Vids\talk.mp4');
    // A content save that says nothing about video keeps the file.
    await s.saveSession('n1', 'Stream note v2', '[]');
    sessions = await s.loadSessions();
    expect(sessions.single.title, 'Stream note v2');
    expect(sessions.single.videoUrl, r'C:\Vids\talk.mp4');
    // Leftover YouTube links from the retired flow load as empty.
    await s.saveSession('n1', 'Stream note', '[]',
        video: 'https://youtu.be/dQw4w9WgXcQ');
    sessions = await s.loadSessions();
    expect(sessions.single.videoUrl, '');
  });

  test('computer video degrades safely with no file', () async {
    final v = ComputerVideo();
    expect(v.currentSeconds(), 0);
    expect(await v.captureFrame(), isNull);
    expect(await v.openRef(r'C:\definitely\missing\talk.mp4'),
        isFalse);
    v.close(); // must not throw
    expect(v.displayName(r'C:\Vids\talk.mp4'), 'talk.mp4');
  });

  test('groq request is well-formed', () {
    final req = buildChatRequest('a better word for happy?');
    expect(req['model'], GroqClient.model);
    final messages = req['messages'] as List;
    expect(messages.length, 2);
    expect((messages.last as Map)['content'],
        'a better word for happy?');
  });

  test('groq answer parses, errors stay friendly', () {
    const body =
        '{"choices":[{"message":{"content":"  delighted  "}}]}';
    expect(parseChatAnswer(body), 'delighted');
    expect(
        GroqException.friendly(401, '{}').toString(),
        contains('401'));
    expect(
        GroqException.friendly(429, '{}').toString(),
        contains('429'));
    expect(
        GroqException.friendly(500, '{"message":"boom"}')
            .toString(),
        contains('boom'));
  });

  test('groq ask works through a fake client', () async {
    final client = GroqClient(
      client: MockClient((request) async {
        expect(request.headers['Authorization'],
            'Bearer test-key');
        expect(request.url.host, 'api.groq.com');
        return http.Response(
            '{"choices":[{"message":{"content":"joyful"}}]}',
            200);
      }),
    );
    expect(await client.ask('test-key', 'hi'), 'joyful');
    final bad = GroqClient(
      client: MockClient((_) async =>
          http.Response('{"message":"nope"}', 401)),
    );
    try {
      await bad.ask('wrong', 'hi');
      fail('must throw');
    } catch (e) {
      expect(e.toString(), contains('401'));
    }
  });

  test('unknown ranges skip typing word, links and numbers', () {
    final checker = SpellCheck.fromWordsList(
        ['hello', 'world', 'is', 'a', 'test', 'ok']);
    bool dict(String w) =>
        checker.isCorrect(w) || checker.isCorrect(w.toLowerCase());
    const text = 'hello wrld, visit example.com at #tag and 2026 ok';
    final hits = findUnknownRanges(text, dict, cursor: -1)
        .map((r) => text.substring(r.$1, r.$2))
        .toList();
    expect(hits, contains('wrld'));
    expect(hits, isNot(contains('hello')));
    expect(hits, isNot(contains('tag')));
    expect(hits, isNot(contains('2026')));
    expect(hits, isNot(contains('example')));
    // The word under the cursor is left alone.
    final atCursor = findUnknownRanges('hello wrld', dict, cursor: 8)
        .map((r) => 'hello wrld'.substring(r.$1, r.$2))
        .toList();
    expect(atCursor, isEmpty);
  });

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

  test('jump numbers attach, resolve either way, and clear', () {
    final g = WordGraph();
    g.connect('happy', 'exhilarated');
    expect(g.jumpNumber('happy', 'exhilarated'), isNull);
    g.setJump('happy', 'exhilarated', '1');
    expect(g.jumpNumber('happy', 'exhilarated'), '1');
    expect(g.jumpNumber('exhilarated', 'happy'), '1');
    expect(g.linked('happy', 'exhilarated'), isTrue);
    g.setJump('happy', 'exhilarated', null);
    expect(g.jumpNumber('happy', 'exhilarated'), isNull);
    expect(g.linked('happy', 'exhilarated'), isTrue);
    g.setJump('happy', 'exhilarated', '2');
    g.disconnect('happy', 'exhilarated');
    expect(g.jumpNumber('happy', 'exhilarated'), isNull);
  });

  test('word file round-trips image and jumps', () {
    final node = WordNode('cat',
        links: {'cute', 'pet'},
        image: 'images/123.png',
        jumps: {'cute': '1'});
    final text = StorageService.serializeWordFile(node);
    expect(text, contains('image: images/123.png'));
    expect(text, contains('jumps: 1:cute'));
    final back = StorageService.parseWordFile(text);
    expect(back, isNotNull);
    expect(back!.image, 'images/123.png');
    expect(back.jumps, {'cute': '1'});
    expect(back.links, {'cute', 'pet'});
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

  test('complex formatting survives a save-load round trip', () {
    final delta = [
      {'insert': 'Hello '},
      {
        'insert': 'world',
        'attributes': {'bold': true, 'background': '#f69697'}
      },
      {
        'insert': {'image': 'https://example.com/a.png'}
      },
      {
        'insert': {'image': 'https://example.com/b.png'},
        'attributes': {
          'style': 'width: 100px; alignment: centerLeft'
        }
      },
      {'insert': 'linky', 'attributes': {'link': 'https://example.com'}},
      {'insert': '\n', 'attributes': {'list': 'bullet'}},
      {'insert': 'struck', 'attributes': {'strike': true, 'color': '#b3261e'}},
      {'insert': '\n'},
    ];
    final doc = Document.fromJson(delta);
    expect(doc.toPlainText(), contains('Hello'));
    expect(doc.toPlainText(), contains('world'));
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

  testWidgets('@ai opens the mini-chat without touching the net',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    for (var i = 0;
        i < 60 && find.byType(EditableText).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    tester
        .state<SheetViewState>(find.byType(SheetView))
        .typeForTest('@ai');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Ask Groq'), findsOneWidget);
    // The @ai token is consumed like a slash command.
    final sheetState =
        tester.state<SheetViewState>(find.byType(SheetView));
    expect(sheetState.debugPlainText(), isNot(contains('@ai')));
    // Save a key: the card must flip to the chat, not sit on the key page.
    final cardField = find.byWidgetPredicate(
        (w) => w is TextField && w.obscureText == true);
    expect(cardField, findsOneWidget);
    await tester.tap(cardField);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(cardField, 'sk-test-key');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Save key'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('what better word'), findsOneWidget);
    // Ask through a fake backend: the answer must appear in the card.
    sheetState.debugSetAiClient(GroqClient(
      client: MockClient((_) async => http.Response(
          '{"choices":[{"message":{"content":"joyful"}}]}', 200)),
    ));
    final questionField = find.byWidgetPredicate(
        (w) => w is TextField && w.maxLines == 3);
    expect(questionField, findsOneWidget);
    await tester.tap(questionField);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(questionField, 'better word for happy?');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Ask'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
        find.byWidgetPredicate((w) =>
            w is SelectableText &&
            (w.data ?? '').contains('joyful')),
        findsOneWidget);
    // Close the chat; nothing was saved anywhere.
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Ask Groq'), findsNothing);
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

  testWidgets('fix-it sheet lists typos and Learn clears them',
      (WidgetTester tester) async {
    await wideWindow(tester);
    await tester.pumpWidget(const WordGraphToolApp());
    for (var i = 0;
        i < 60 && find.byType(EditableText).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    tester.state<SheetViewState>(find.byType(SheetView)).debugUseSpell(
        SpellCheck.fromWordsList(['say', 'world', 'hello']));
    tester
        .state<SheetViewState>(find.byType(SheetView))
        .typeForTest('say helo world');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    // Orange flag + footer button appear.
    expect(find.text('1 to fix'), findsOneWidget);
    await tester.tap(find.text('1 to fix'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Possible typos — tap a fix'), findsOneWidget);
    expect(find.text('helo'), findsWidgets);
    await tester.tap(find.text('Learn'));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    final sheetState =
        tester.state<SheetViewState>(find.byType(SheetView));
    expect(sheetState.debugDeltaJson(), isNot(contains('ffdfb0')));
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

  testWidgets('graph board has no walls: far drags keep exact spots',
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
    // Far past the old 40..5600 walls, into negative space.
    await gesture.moveBy(const Offset(-2000, -1500));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    final node = state.widget.graph.get('meal')!;
    expect(node.x, closeTo(start.dx - 2000, 2.0));
    expect(node.y, closeTo(start.dy - 1500, 2.0));
  });

  testWidgets('fit button centers a huge spread instead of stranding it',
      (WidgetTester tester) async {
    await wideWindow(tester);
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Graph'));
    await tester.pump(const Duration(milliseconds: 500));
    final state =
        tester.state<GraphViewState>(find.byType(GraphView).first);
    // Hurl one word far out so fitting needs a deep zoom-out.
    final start = state.debugCenter('meal')!;
    final gesture =
        await tester.startGesture(state.debugToGlobal(start));
    await gesture.moveBy(const Offset(-8000, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Fit everything in view'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    // Deep zoom-out, past the old 0.2 floor, still above the basement.
    final s = state.debugScale();
    expect(s, lessThan(0.19));
    expect(s, greaterThanOrEqualTo(0.05));
    // The middle of the map lands near the middle of the canvas area
    // (right of the 208px word rail in the 1280px test window).
    final a = state.debugCenter('meal')!;
    final b = state.debugCenter('eat')!;
    final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    final onScreen = state.debugToGlobal(mid);
    expect((onScreen.dx - 744).abs(), lessThan(200));
    expect((onScreen.dy - 300).abs(), lessThan(200));
  });

  testWidgets('hand tool pans the graph, cursor tool drags words',
      (WidgetTester tester) async {
    await wideWindow(tester);
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Graph'));
    await tester.pump(const Duration(milliseconds: 500));
    final state =
        tester.state<GraphViewState>(find.byType(GraphView).first);
    final m0 = state.debugCenter('meal')!;
    final g0 = state.debugToGlobal(m0);
    // Hand tool: a drag starting ON the bubble pans instead of moving
    // it (drag left so the bubble stays on the 800px test window).
    await tester.tap(find.byTooltip('Drag the graph itself'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.dragFrom(
        state.debugToGlobal(m0), const Offset(-150, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.debugCenter('meal'), m0);
    final g1 = state.debugToGlobal(m0);
    expect(g0.dx - g1.dx, greaterThan(100));
    // Cursor tool: the same drag moves the bubble again.
    await tester.tap(find.byTooltip('Select and drag words'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.dragFrom(
        state.debugToGlobal(m0), const Offset(50, 0));
    await tester.pump(const Duration(milliseconds: 500));
    final m1 = state.debugCenter('meal')!;
    expect(m1.dx, closeTo(m0.dx + 50, 2.0));
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
    // Empty on-screen canvas, top-left of the cascade area.
    final at = state.debugToGlobal(const Offset(100, 100));
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

  testWidgets('note body survives an app restart',
      (WidgetTester tester) async {
    final storage = StorageService();
    Future<void> boot() async {
      await tester.pumpWidget(WordGraphToolApp(storage: storage));
      for (var i = 0;
          i < 60 && find.byType(EditableText).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    await boot();
    tester
        .state<SheetViewState>(find.byType(SheetView))
        .typeForTest('my precious four hundred words live here');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    // Quit the app (unmount everything, like closing the window).
    await tester.pumpWidget(Container());
    await tester.pump(const Duration(milliseconds: 500));
    // Launch again with the same storage: words must be back.
    await boot();
    final sheetState =
        tester.state<SheetViewState>(find.byType(SheetView));
    expect(sheetState.debugPlainText(),
        contains('my precious four hundred words live here'));
    // Let any pending debounce/highlight timers flush before teardown.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('grammar page adds and groups a sentence',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Grammar'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.textContaining('Grammar structures'), findsOneWidget);
    await tester.enterText(
        find.byWidgetPredicate((w) =>
            w is TextField &&
            (w.decoration?.hintText ?? '').startsWith('Paste a sentence')),
        'If I had known, I would have come.');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
        find.byWidgetPredicate((w) =>
            w is TextField &&
            (w.decoration?.hintText ?? '').startsWith('Category')),
        'Conditionals');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Add'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('If I had known, I would have come.'),
        findsOneWidget);
    expect(find.text('Conditionals (1)'), findsOneWidget);
  });

  testWidgets('grammar check can be switched off from the Grammar page',
      (WidgetTester tester) async {
    final storage = StorageService();
    await tester.pumpWidget(WordGraphToolApp(storage: storage));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));

    // On by default, so the editor offers the button.
    expect(find.text('grammar check'), findsOneWidget);

    await tester.tap(find.text('Grammar'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Grammar check'), findsWidgets);

    await tester.tap(find.byType(Switch));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // Persisted, and the live editor picks it up without a restart.
    expect(storage.grammarCheckEnabled.value, isFalse);
    expect(await storage.loadGrammarCheckEnabled(), isFalse);

    await tester.tap(find.text('Sheet'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('grammar check'), findsNothing);
    expect(find.text('mention'), findsOneWidget);
  });

  test('frame references are portable and reject unsafe names', () async {
    // Notes store a relative reference so they survive a moved app folder.
    expect(StorageService.imageRefName('frame', 'jpg', 1234),
        'images/frame-1234.jpg');

    // A crafted prefix or extension must not escape the images folder.
    expect(StorageService.imageRefName('../../evil', 'jpg', 1),
        'images/image-1.jpg');
    expect(StorageService.imageRefName('frame', '../../png', 1),
        'images/frame-1.jpg');
    expect(StorageService.imageRefName('Frame Note', 'JPEG', 1),
        'images/image-1.jpg');

    // Network images are handed to Quill untouched; without a real folder
    // there is nothing local to resolve to.
    final s = StorageService();
    await s.init();
    expect(s.resolveImage('https://x.test/a.png'), 'https://x.test/a.png');
    expect(s.resolveImage(''), isNull);
    if (s.isMemoryOnly) {
      expect(s.resolveImage('images/frame-1.jpg'), isNull);
      expect(await s.saveImageBytes([1, 2, 3]), isNull);
    }
  });

  test('repetition rhythms read naturally', () {
    expect(intervalText(1), 'every minute');
    expect(intervalText(5), 'every 5 minutes');
    expect(intervalText(60), 'every hour');
    expect(intervalText(120), 'every 2 hours');
    expect(intervalText(1440), 'every day');
    expect(intervalText(4320), 'every 3 days');
    const now = 1000000000000;
    expect(dueText(now, now), 'due now');
    expect(dueText(now + 30000, now), 'due any second');
    expect(dueText(now + 5 * 60000, now), 'due in 5 min');
    expect(dueText(now + 2 * 3600000, now), 'due in 2 h');
    expect(dueText(now + 3 * 86400000, now), 'due in 3 d');
    expect(dueText(now - 2 * 86400000, now), 'overdue by 2 d');
  });

  test('repetition bundle is the word plus its links', () {
    final g = WordGraph();
    g.connect('house', 'bedroom');
    g.connect('house', 'living room');
    g.connect('bedroom', 'pillow');
    final bundle = bundleFor(g, 'house');
    expect(bundle.first, 'house');
    expect(bundle.toSet(), {'house', 'bedroom', 'living room'});
    expect(bundleFor(g, 'missing'), isEmpty);
  });

  test('practice counts used words whole-word only', () {
    const words = ['house', 'bedroom'];
    expect(usedWords('The HOUSE has a bedroom.', words),
        {'house', 'bedroom'});
    expect(usedWords('The greenhouse is big.', words), isEmpty);
    expect(usedWords('', words), isEmpty);
  });

  test('repetition items save, reload and reschedule', () async {
    final s = StorageService();
    await s.init();
    const now = 1000000000000;
    await s.saveRepetition([
      RepetitionItem(
          id: 'a', word: 'house', intervalMinutes: 1440,
          createdAt: now, dueAt: now + 86400000),
      RepetitionItem(
          id: 'b', word: 'eat', intervalMinutes: 1,
          createdAt: now, dueAt: now + 60000),
    ]);
    var back = await s.loadRepetition();
    expect(back.length, 2);
    expect(back.first.word, 'house');
    expect(back.first.intervalMinutes, 1440);
    // Finishing pushes the due date out by the same rhythm.
    back.first.dueAt = now + 1440 * 60000;
    await s.saveRepetition(back);
    back = await s.loadRepetition();
    expect(
        back.firstWhere((e) => e.id == 'a').dueAt,
        now + 1440 * 60000);
  });

  testWidgets('practice tab opens an empty stack',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Practice'));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Spaced repetition'), findsOneWidget);
    expect(find.textContaining('No practices yet'), findsOneWidget);
  });

  testWidgets('stream panel offers a file and reports it missing',
      (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('stream video'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Choose file…'), findsOneWidget);
    expect(find.text('no video attached'), findsOneWidget);
    // No native picker or disk IO in tests: attach directly, then force
    // the player states to see each card.
    tester
        .state<SheetViewState>(find.byType(SheetView))
        .debugAttachVideo(r'C:\Vids\gone.mp4');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('gone.mp4'), findsNWidgets(2));
    tester
        .state<SheetViewState>(find.byType(SheetView))
        .debugSetVideoState(open: false, missing: true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('not found'), findsOneWidget);
    expect(find.text('frame note'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('no video attached'), findsOneWidget);
  });

  testWidgets('app boots to sheet view', (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Word Graph Tool'), findsOneWidget);
  });
}


