import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/legado/book_source.dart';
import 'package:fqapp/legado/web_book.dart';
import 'package:fqapp/pages/search_book_source.dart';
import 'package:fqapp/pages/search_page.dart';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'search_list_view': false}),
  );

  test('scope keeps groups and skips disabled or non-text sources', () {
    final sources = [
      _source('https://a', '甲书源', group: '玄幻，都市'),
      _source('https://b', '乙书源', group: '都市'),
      _source('https://c', '停用', enabled: false),
      _source('https://d', '有声', type: 1),
    ];

    expect(
      bookSourceScopeChoices(sources).map((choice) => choice.label).toList(),
      ['全部', '玄幻', '都市', '甲书源', '乙书源'],
    );
    expect(sourcesInScope(sources, 'g:玄幻').map((source) => source.url), [
      'https://a',
    ]);
    expect(
      sourcesInScope(sources, 's:https://b').map((source) => source.name),
      ['乙书源'],
    );
    expect(sourcesInScope(sources, '').map((source) => source.url), [
      'https://a',
      'https://b',
    ]);
  });

  testWidgets('bookstore search can search imported book sources by scope', (
    tester,
  ) async {
    final calls = <(String, List<String>)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          searchLoader:
              (_, {required int tabType, required int offset}) async =>
                  const [],
          bookSourceCatalog: () async => [
            _source('https://a', '甲书源', group: '玄幻'),
            _source('https://b', '乙书源', group: '都市'),
          ],
          bookSourceQuery: ({required sources, required keyword}) async {
            calls.add((keyword, [for (final source in sources) source.url]));
            final source = sources.first;
            return LegadoSearchBatch([
              LegadoHit(
                source: source,
                name: '${source.name}的$keyword',
                bookUrl: 'https://book/${source.url}',
              ),
            ], const []);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('search-source-book')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, '全部'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '玄幻'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '甲书源'), findsOneWidget);
    expect(find.text('搜索书名'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '斗破');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(calls.single.$1, '斗破');
    expect(calls.single.$2, ['https://a', 'https://b']);
    expect(find.text('甲书源的斗破'), findsOneWidget);
    expect(find.text('按已添加的书源搜索'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '乙书源'));
    await tester.pumpAndSettle();
    expect(calls.last.$1, '斗破');
    expect(calls.last.$2, ['https://b']);
    expect(find.text('乙书源的斗破'), findsOneWidget);
  });

  testWidgets('book source search explains when nothing is enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          searchLoader:
              (_, {required int tabType, required int offset}) async =>
                  const [],
          bookSourceCatalog: () async => const [],
          bookSourceQuery: ({required sources, required keyword}) async =>
              const LegadoSearchBatch([], []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-source-book')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '斗破');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text(bookSourceEmptyMessage), findsOneWidget);
  });
}

LegadoBookSource _source(
  String url,
  String name, {
  String group = '',
  bool enabled = true,
  int type = 0,
}) => LegadoBookSource({
  'bookSourceUrl': url,
  'bookSourceName': name,
  'bookSourceGroup': group,
  'bookSourceType': type,
  'enabled': enabled,
});
