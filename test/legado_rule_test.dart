import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/source_search_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:fqapp/legado/analyze_url.dart';
import 'package:fqapp/legado/book_source.dart';
import 'package:fqapp/legado/charset.dart';
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

  test('chapter rules match the anchor itself', () async {
    final chapters = await _loadToc(
      const {
        'chapterList': 'id.list@tag.a',
        'chapterName': 'tag.a@text',
        'chapterUrl': 'tag.a@href',
      },
      '''
      <div id="list">
        <a href="/c/1">第一章</a>
        <a href="/c/2">第二章</a>
      </div>
      ''',
    );
    expect(chapters.map((chapter) => chapter.title), ['第一章', '第二章']);
    expect(chapters.map((chapter) => chapter.itemId), [
      'https://ex.com/c/1',
      'https://ex.com/c/2',
    ]);
  });

  test('bare text and href read the current anchor', () async {
    final chapters = await _loadToc(const {
      'chapterList': 'id.list@tag.a',
      'chapterName': 'text',
      'chapterUrl': 'href',
    }, '<div id="list"><a href="/c/1">第一章</a></div>');
    expect(chapters.single.title, '第一章');
    expect(chapters.single.itemId, 'https://ex.com/c/1');
  });

  test('css, at-css and xpath chapter lists are read', () async {
    const html = '''
      <div id="list"><a href="/c/1">第一章</a><a href="/c/2">第二章</a></div>
    ''';
    for (final rule in ['@CSS:#list a', '@@#list a', "//div[@id='list']/a"]) {
      final chapters = await _loadToc({
        'chapterList': rule,
        'chapterName': 'text',
        'chapterUrl': 'href',
      }, html);
      expect(chapters.map((chapter) => chapter.title), [
        '第一章',
        '第二章',
      ], reason: rule);
    }
  });

  test('a negative chapter range is read from the end', () async {
    final chapters = await _loadToc(
      const {
        'chapterList': 'id.list@tag.a[-1:0]',
        'chapterName': 'text',
        'chapterUrl': 'href',
      },
      '''
      <div id="list">
        <a href="/c/1">第一章</a>
        <a href="/c/2">第二章</a>
        <a href="/c/3">第三章</a>
      </div>
      ''',
    );
    expect(chapters.map((chapter) => chapter.title), ['第三章', '第二章', '第一章']);
  });

  test('a chapter with a title and no url is still listed', () async {
    final chapters = await _loadToc(
      const {
        'chapterList': 'class.chapter',
        'chapterName': 'text',
        'chapterUrl': 'tag.missing@href',
      },
      '''
      <div class="chapter"><a href="/c/1">第一章</a></div>
      <div class="chapter">第二章</div>
      ''',
    );
    expect(chapters.map((chapter) => chapter.title), ['第一章', '第二章']);
    expect(chapters.first.itemId, 'https://ex.com/c/1');
  });

  test('javascript chapter links use the address in onclick', () async {
    final chapters = await _loadToc(
      const {
        'chapterList': 'id.list@tag.a',
        'chapterName': 'text',
        'chapterUrl': 'href',
      },
      '''
      <div id="list">
        <a href="javascript:;" onclick="location.href='/c/1.html'">第一章</a>
      </div>
      ''',
    );
    expect(chapters.single.itemId, 'https://ex.com/c/1.html');
  });

  test('paragraphs under the chapter title are the body', () async {
    final source = LegadoBookSource({
      'bookSourceUrl': 'https://ex.com',
      'bookSourceName': '正文',
      'ruleContent': {'content': 'id.content@textNodes'},
    });
    LegadoRequest? seen;
    final text = await loadLegadoContent(
      source,
      'https://ex.com/c/1',
      fetch: (request) async {
        seen = request;
        return const LegadoFetched('''
          <div id="content">
            第一章 开端
            <p>正文第一段，这里才是小说。</p>
            <p>正文第二段。</p>
          </div>
          ''', 'https://ex.com/c/1');
      },
    );
    expect(text, contains('正文第一段，这里才是小说。'));
    expect(text, contains('正文第二段。'));
    expect(seen?.headers['Referer'], 'https://ex.com');
  });

  test('a leading paragraph can be excluded from the body', () async {
    final text = await _content('id.content@tag.p!0@text', '''
      <div id="content">
        <p>第一章 标题</p>
        <p>真正的正文。</p>
      </div>
      ''');
    expect(text, contains('真正的正文。'));
    expect(text, isNot(contains('标题')));
  });

  test('a regex extracts the chapter and ignores the catalog', () async {
    final text = await _content(
      r'##<div id="content">([\s\S]*?)</div>##$1##',
      '''
      <div id="side">目录一章</div>
      <div id="content"><p>正文在这里。</p></div>
      ''',
    );
    expect(text, contains('正文在这里。'));
    expect(text, isNot(contains('目录一章')));
  });

  test('javascript escaped chapter html is unescaped', () async {
    final text = await _content(
      r'''##content\s*=\s*"(.*?)"##$1##''',
      r'''
      <script>var content = "\u003cp\u003e转义后的正文\u003c/p\u003e";</script>
      ''',
    );
    expect(text, contains('转义后的正文'));
  });

  test('a chapter link list is not treated as the body', () async {
    final text = await _content('id.content@text', '''
      <div id="content">
        <p>这是小说正文段落。</p>
        <div class="list">
          <a>第一章</a><a>第二章</a><a>第三章</a><a>第四章</a><a>第五章</a>
        </div>
      </div>
      ''');
    expect(text, contains('这是小说正文段落。'));
    expect(text, isNot(contains('第五章')));
  });

  test('xpath text nodes are the body', () async {
    final text = await _content(
      "//div[@id='content']/text()",
      '<div id="content">直接写在节点上的正文</div>',
    );
    expect(text, contains('直接写在节点上的正文'));
  });

  test('gbk pages and declared charset decode as chinese', () {
    final coded = gbk.encode('正文第一段');
    expect(decodeLegadoBytes(coded), contains('正文第一段'));
    final page = gbk.encode('<meta charset="gb2312"><div>网页正文</div>');
    expect(decodeLegadoBytes(page), contains('网页正文'));
    final request = analyzeLegadoUrl(
      'https://ex.com/s,{"charset":"gbk"}',
      base: 'https://ex.com',
    );
    expect(request.charset, 'gbk');
  });

  test(
    'slow sources do not block hits from the ones that already returned',
    () async {
      final slow = Completer<void>();
      var running = 0;
      var peak = 0;
      final progress = <int>[];
      final pending = searchLegadoSources(
        sources: [for (var i = 0; i < 4; i++) _htmlSource(i)],
        keyword: '雪中',
        concurrency: 2,
        onProgress: (update) => progress.add(update.hits.length),
        fetch: (request) async {
          running++;
          peak = math.max(peak, running);
          final index = int.parse(request.url.pathSegments.first);
          if (index == 3) await slow.future;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          running--;
          return LegadoFetched(
            '<div class="item"><a href="/b/$index">书$index</a></div>',
            request.url.toString(),
          );
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(progress.last, 3);
      expect(peak, 2);
      slow.complete();
      final batch = await pending;
      expect(batch.hits, hasLength(4));
      expect(batch.errors, isEmpty);
    },
  );

  testWidgets('search page lists a finished source before the slow one', (
    tester,
  ) async {
    final slow = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: SourceSearchPage(
          keyword: '雪中',
          sources: [_htmlSource(0), _htmlSource(1)],
          fetch: (request) async {
            final index = int.parse(request.url.pathSegments.first);
            if (index == 1) await slow.future;
            return LegadoFetched(
              '<div class="item"><a href="/b/$index">书$index</a></div>',
              request.url.toString(),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('书0'), findsOneWidget);
    expect(find.text('正在搜索 1/2'), findsOneWidget);
    expect(find.text('书1'), findsNothing);
    slow.complete();
    await tester.pumpAndSettle();
    expect(find.text('搜索完成 2/2'), findsOneWidget);
    expect(find.text('书1'), findsOneWidget);
  });
}

Future<String> _content(String rule, String html) {
  return loadLegadoContent(
    LegadoBookSource({
      'bookSourceUrl': 'https://ex.com',
      'bookSourceName': '正文',
      'ruleContent': {'content': rule},
    }),
    'https://ex.com/c/1',
    fetch: (_) async => LegadoFetched(html, 'https://ex.com/c/1'),
  );
}

Future<List<Chapter>> _loadToc(Map<String, String> toc, String html) {
  return loadLegadoChapters(
    LegadoHit(
      source: LegadoBookSource({
        'bookSourceUrl': 'https://ex.com',
        'bookSourceName': '目录',
        'ruleToc': toc,
      }),
      name: '书',
      bookUrl: 'https://ex.com/b/1',
    ),
    fetch: (_) async => LegadoFetched(html, 'https://ex.com/b/1'),
  );
}

LegadoBookSource _htmlSource(int index) => LegadoBookSource({
  'bookSourceUrl': 'https://ex.com/$index',
  'bookSourceName': '源$index',
  'searchUrl': 'https://ex.com/$index/s?q={{key}}',
  'ruleSearch': {
    'bookList': 'class.item',
    'name': 'tag.a@text',
    'bookUrl': 'tag.a@href',
  },
});
