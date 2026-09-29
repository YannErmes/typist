import 'package:flutter_test/flutter_test.dart';
import 'package:word_graph_tool/graph_model.dart';
import 'package:word_graph_tool/main.dart';
import 'package:word_graph_tool/storage.dart';

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

  test('word file round-trips parents and children', () {
    final node = WordNode('eat',
        parents: {'meal', 'food'}, children: {'orange', 'tomato'});
    final text = StorageService.serializeWordFile(node);
    final back = StorageService.parseWordFile(text);
    expect(back, isNotNull);
    expect(back!.parents, {'meal', 'food'});
    expect(back.children, {'orange', 'tomato'});
  });

  testWidgets('app boots to sheet view', (WidgetTester tester) async {
    await tester.pumpWidget(const WordGraphToolApp());
    await tester.pump();
    expect(find.text('Word Graph Tool'), findsOneWidget);
  });
}
