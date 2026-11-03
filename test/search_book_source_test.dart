import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/search_history_store.dart';
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
      ['全部', '校验可用', '玄幻', '都市'],
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
    final checked = [
      _source('https://a', '甲书源').withCheck('ok'),
      _source('https://b', '乙书源').withCheck('fail', enabled: false),
    ];
    expect(sourcesInScope(checked, 'ok').map((source) => source.url), [
      'https://a',
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
    expect(find.byKey(const Key('search-book-scope')), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('搜索书名'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '斗破');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(calls.single.$1, '斗破');
    expect(calls.single.$2, ['https://a', 'https://b']);
    expect(find.text('甲书源的斗破'), findsOneWidget);
    expect(find.text('按已添加的书源搜索'), findsOneWidget);

    await tester.tap(find.byKey(const Key('search-book-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('都市').last);
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

  testWidgets('book source history search does not crash', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          historyStore: _History(['斗破']),
          searchLoader:
              (_, {required int tabType, required int offset}) async =>
                  const [],
          bookSourceCatalog: () async => [_source('https://a', '甲书源')],
          bookSourceQuery: ({required sources, required keyword}) async {
            calls.add(keyword);
            return LegadoSearchBatch([
              LegadoHit(
                source: sources.first,
                name: keyword,
                bookUrl: 'https://a/book',
              ),
            ], const []);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-source-book')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('斗破'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(calls, ['斗破']);
    expect(find.text('斗破'), findsWidgets);

    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('斗破'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(calls, ['斗破', '斗破']);
  });

  testWidgets('book source history search uses the real source rules', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          historyStore: _History(['斗破']),
          searchLoader:
              (_, {required int tabType, required int offset}) async =>
                  const [],
          bookSourceCatalog: () async => [
            LegadoBookSource({
              'bookSourceUrl': 'https://ex.com',
              'bookSourceName': '甲书源',
              'enabled': true,
              'bookSourceType': 0,
              'searchUrl': 'https://ex.com/s?q={{key}}',
              'ruleSearch': {
                'bookList': 'class.item',
                'name': 'tag.a@text',
                'bookUrl': 'tag.a@href',
              },
            }),
          ],
          bookSourceFetch: (request) async => LegadoFetched(
            '<div class="item"><a href="/b/1">斗破苍穹</a></div>',
            request.url.toString(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-source-book')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('斗破'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('斗破苍穹'), findsOneWidget);
  });
}

class _History implements SearchHistoryRepository {
  _History(this.items);
  List<String> items;

  @override
  Future<List<String>> load() async => items;

  @override
  Future<List<String>> add(String query) async =>
      items = mergeSearchHistory(items, query);

  @override
  Future<List<String>> remove(String query) async =>
      items = items.where((value) => value != query).toList();

  @override
  Future<void> clear() async => items = [];
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
