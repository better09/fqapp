import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/legado/analyze_url.dart';
import 'package:fqapp/legado/book_source.dart';
import 'package:fqapp/legado/rules.dart';
import 'package:fqapp/legado/web_book.dart';

void main() {
  test('html rules read a book list and join fields', () {
    const html = '''
      <div class="item"><a href="/b/1">第一本</a><span class="author">甲</span></div>
      <div class="item"><a href="/b/2">第二本</a><span class="author">乙</span></div>
    ''';
    final document = parseLegadoDocument(html);
    final nodes = legadoNodes(document, 'class.item');
    expect(nodes, hasLength(2));
    expect(
      legadoFirst(nodes.first, 'tag.a@text', baseUrl: 'https://ex.com/s'),
      '第一本',
    );
    expect(
      legadoFirst(nodes.first, 'tag.a@href', baseUrl: 'https://ex.com/s'),
      'https://ex.com/b/1',
    );
    expect(
      legadoTexts(
        nodes.first,
        'tag.a@text&&class.author@text',
        baseUrl: 'https://ex.com/s',
      ),
      ['第一本', '甲'],
    );
  });

  test('json path reads a list and || falls back', () {
    final document = parseLegadoDocument(
      '{"data":[{"name":"甲","url":"/a"},{"name":"乙","url":"/b"}]}',
    );
    final nodes = legadoNodes(document, r'$.missing||$.data');
    expect(nodes, hasLength(2));
    expect(legadoFirst(nodes.last, r'$.name', baseUrl: 'https://ex.com'), '乙');
    expect(
      legadoFirst(nodes.first, r'$.url', baseUrl: 'https://ex.com/search'),
      'https://ex.com/a',
    );
  });

  test('replace rules strip ads from chapter text', () {
    expect(legadoTexts('正文广告词结尾', '##广告词##', baseUrl: ''), ['正文结尾']);
  });

  test('search url fills the keyword, page list and post body', () {
    final request = analyzeLegadoUrl(
      'https://ex.com/<search,search2>,{"method":"POST","body":"q={{key}}&p={{page}}"}',
      base: 'https://ex.com',
      key: '雪中',
      page: 2,
    );
    expect(request.url.toString(), 'https://ex.com/search2');
    expect(request.method, 'POST');
    expect(request.body, 'q=雪中&p=2');
  });

  test('a legado source searches html and stops on javascript rules', () async {
    final source = parseBookSources('''
      [{
        "bookSourceUrl": "https://ex.com",
        "bookSourceName": "示例",
        "searchUrl": "https://ex.com/s?q={{key}}",
        "ruleSearch": {
          "bookList": "class.item",
          "name": "tag.a@text",
          "author": "class.author@text",
          "bookUrl": "tag.a@href"
        },
        "ruleToc": {
          "chapterList": "class.chapter",
          "chapterName": "tag.a@text",
          "chapterUrl": "tag.a@href"
        },
        "ruleContent": {"content": "id.content@html", "replaceRegex": "##广告##"}
      }]
    ''').single;

    final batch = await searchLegadoSources(
      sources: [source],
      keyword: '雪中',
      fetch: (request) async {
        expect(request.url.queryParameters['q'], '雪中');
        return const LegadoFetched('''
          <div class="item"><a href="/b/1">雪中悍刀行</a><span class="author">烽火</span></div>
        ''', 'https://ex.com/s');
      },
    );
    expect(batch.errors, isEmpty);
    expect(batch.hits.single.bookUrl, 'https://ex.com/b/1');

    final chapters = await loadLegadoChapters(
      batch.hits.single,
      fetch: (request) async => const LegadoFetched('''
        <div class="chapter"><a href="/c/1">第一章</a></div>
        <div class="chapter"><a href="/c/2">第二章</a></div>
      ''', 'https://ex.com/b/1'),
    );
    expect(chapters.map((chapter) => chapter.title), ['第一章', '第二章']);

    final text = await loadLegadoContent(
      source,
      chapters.first.itemId,
      fetch: (request) async => const LegadoFetched(
        '<div id="content"><p>第一段</p>广告<br>第二段</div>',
        'https://ex.com/c/1',
      ),
    );
    expect(text, contains('第一段'));
    expect(text, isNot(contains('广告')));

    final scripted = source.raw;
    // 带 JS 的搜索规则要明确失败，不能当成空结果。
    final broken = LegadoBookSource({
      ...scripted,
      'ruleSearch': {
        'bookList': '@js:[]',
        'name': 'tag.a@text',
        'bookUrl': 'tag.a@href',
      },
    });
    final failed = await searchLegadoSources(
      sources: [broken],
      keyword: '雪中',
      fetch: (_) async => const LegadoFetched('', 'https://ex.com'),
    );
    expect(failed.errors.single, contains('JavaScript'));
  });
}
