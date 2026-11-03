import 'dart:convert';

import 'package:html/dom.dart';
import 'package:http/http.dart' as http;

import '../models/media_item.dart';
import 'analyze_url.dart';
import 'book_source.dart';
import 'rules.dart';

class LegadoException implements Exception {
  final String message;
  LegadoException(this.message);
  @override
  String toString() => message;
}

/// 一次搜索命中的书。
class LegadoHit {
  final LegadoBookSource source;
  final String name;
  final String author;
  final String bookUrl;
  final String cover;
  final String intro;
  final String lastChapter;

  const LegadoHit({
    required this.source,
    required this.name,
    required this.bookUrl,
    this.author = '',
    this.cover = '',
    this.intro = '',
    this.lastChapter = '',
  });

  MediaItem toMediaItem() => MediaItem(
    id: bookUrl,
    title: name,
    cover: cover,
    author: author,
    badge: source.name,
    ep: lastChapter,
    kind: 'book',
    intro: intro,
    seriesId: source.url,
    source: legadoSourceMark,
  );
}

class LegadoSearchBatch {
  final List<LegadoHit> hits;
  final List<String> errors;
  const LegadoSearchBatch(this.hits, this.errors);
}

typedef LegadoFetcher = Future<LegadoFetched> Function(LegadoRequest request);

class LegadoFetched {
  final String body;
  final String url;
  const LegadoFetched(this.body, this.url);
}

Future<LegadoFetched> fetchLegado(LegadoRequest request) async {
  final client = http.Client();
  try {
    final outgoing = http.Request(request.method, request.url)
      ..headers.addAll(request.headers);
    if (request.body != null && request.method != 'GET') {
      outgoing.body = request.body!;
    }
    final response = await client
        .send(outgoing)
        .timeout(const Duration(seconds: 20));
    final bytes = await response.stream.toBytes();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LegadoException('请求失败（${response.statusCode}）');
    }
    final url = response.request?.url.toString() ?? request.url.toString();
    return LegadoFetched(utf8.decode(bytes, allowMalformed: true), url);
  } finally {
    client.close();
  }
}

Future<LegadoSearchBatch> searchLegadoSources({
  required List<LegadoBookSource> sources,
  required String keyword,
  LegadoFetcher fetch = fetchLegado,
}) async {
  final hits = <LegadoHit>[];
  final errors = <String>[];
  for (final source in sources.where(
    (item) => item.enabled && item.type == 0,
  )) {
    try {
      hits.addAll(await _searchOne(source, keyword, fetch));
    } on LegadoException catch (error) {
      errors.add('${source.name}：${error.message}');
    } catch (error) {
      errors.add('${source.name}：$error');
    }
  }
  return LegadoSearchBatch(hits, errors);
}

Future<List<LegadoHit>> _searchOne(
  LegadoBookSource source,
  String keyword,
  LegadoFetcher fetch,
) async {
  final searchUrl = source.searchUrl;
  final bookList = source.search.bookList;
  if (searchUrl == null || bookList == null) {
    throw LegadoException('没有搜索地址或书单规则');
  }
  _rejectJs([searchUrl, bookList, source.search.name, source.search.bookUrl]);
  final page = await fetch(
    analyzeLegadoUrl(
      searchUrl,
      base: source.url,
      key: keyword,
      headers: source.headers,
    ),
  );
  final document = parseLegadoDocument(page.body);
  final nodes = legadoNodes(document, bookList);
  final hits = <LegadoHit>[];
  for (final node in nodes) {
    final hit = _hitFrom(source, node, page.url);
    if (hit != null) hits.add(hit);
  }
  return hits;
}

LegadoHit? _hitFrom(LegadoBookSource source, Object node, String pageUrl) {
  final rule = source.search;
  final name = legadoFirst(node, rule.name, baseUrl: pageUrl);
  final bookUrl = legadoFirst(node, rule.bookUrl, baseUrl: pageUrl);
  if (name.isEmpty || bookUrl.isEmpty) return null;
  return LegadoHit(
    source: source,
    name: name,
    bookUrl: bookUrl,
    author: legadoFirst(node, rule.author, baseUrl: pageUrl),
    cover: legadoFirst(node, rule.coverUrl, baseUrl: pageUrl),
    intro: legadoFirst(node, rule.intro, baseUrl: pageUrl),
    lastChapter: legadoFirst(node, rule.lastChapter, baseUrl: pageUrl),
  );
}

Future<List<Chapter>> loadLegadoChapters(
  LegadoHit hit, {
  LegadoFetcher fetch = fetchLegado,
}) async {
  final source = hit.source;
  _rejectJs([
    source.bookInfo.tocUrl,
    source.toc.chapterList,
    source.toc.chapterName,
    source.toc.chapterUrl,
    source.toc.nextTocUrl,
  ]);
  final book = await fetch(_get(hit.bookUrl, source));
  final tocTarget = legadoFirst(
    parseLegadoDocument(book.body),
    source.bookInfo.tocUrl,
    baseUrl: book.url,
  );
  final tocUrl = tocTarget.isEmpty ? book.url : tocTarget;
  final first = tocUrl == book.url ? book : await fetch(_get(tocUrl, source));
  return _chaptersFrom(source, first, fetch);
}

Future<List<Chapter>> _chaptersFrom(
  LegadoBookSource source,
  LegadoFetched page,
  LegadoFetcher fetch,
) async {
  final chapters = <Chapter>[];
  final seen = <String>{};
  var current = page;
  for (var hop = 0; hop < 20; hop++) {
    final document = parseLegadoDocument(current.body);
    chapters.addAll(_readChapterPage(source, document, current.url, seen));
    final next = legadoFirst(
      document,
      source.toc.nextTocUrl,
      baseUrl: current.url,
    );
    if (next.isEmpty || !seen.add('toc:$next')) break;
    current = await fetch(_get(next, source));
  }
  if (chapters.isEmpty) throw LegadoException('没有解析到目录');
  return chapters;
}

List<Chapter> _readChapterPage(
  LegadoBookSource source,
  Object document,
  String pageUrl,
  Set<String> seen,
) {
  final chapters = <Chapter>[];
  for (final node in legadoNodes(document, source.toc.chapterList)) {
    if (_isVolume(node, source.toc.isVolume, pageUrl)) continue;
    final name = legadoFirst(node, source.toc.chapterName, baseUrl: pageUrl);
    final url = legadoFirst(node, source.toc.chapterUrl, baseUrl: pageUrl);
    if (name.isEmpty || url.isEmpty || !seen.add(url)) continue;
    chapters.add(Chapter(itemId: url, title: name, volumeName: ''));
  }
  return chapters;
}

bool _isVolume(Object node, String? rule, String pageUrl) {
  final mark = legadoFirst(node, rule, baseUrl: pageUrl).toLowerCase();
  return mark == '1' || mark == 'true' || mark == '是';
}

Future<String> loadLegadoContent(
  LegadoBookSource source,
  String chapterUrl, {
  LegadoFetcher fetch = fetchLegado,
}) async {
  _rejectJs([
    source.content.content,
    source.content.nextContentUrl,
    source.content.replaceRegex,
  ]);
  final buffer = StringBuffer();
  final seen = <String>{chapterUrl};
  var url = chapterUrl;
  for (var hop = 0; hop < 5; hop++) {
    final page = await fetch(_get(url, source));
    final document = parseLegadoDocument(page.body);
    buffer.writeln(
      legadoTexts(
        document,
        source.content.content,
        baseUrl: page.url,
      ).join('\n'),
    );
    final next = legadoFirst(
      document,
      source.content.nextContentUrl,
      baseUrl: page.url,
    );
    if (next.isEmpty || !seen.add(next)) break;
    url = next;
  }
  var text = buffer.toString().trim();
  final replace = source.content.replaceRegex;
  if (replace != null) {
    text = legadoTexts(text, replace, baseUrl: chapterUrl).join('\n').trim();
  }
  text = _plainContent(text);
  if (text.isEmpty) throw LegadoException('正文为空');
  return text;
}

String _plainContent(String raw) {
  if (!raw.contains('<')) return raw.trim();
  final withBreaks = raw
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n');
  final document = parseLegadoDocument(withBreaks);
  final plain = document is Element ? document.text : raw;
  return plain.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

LegadoRequest _get(String url, LegadoBookSource source) {
  return analyzeLegadoUrl(url, base: source.url, headers: source.headers);
}

void _rejectJs(List<String?> rules) {
  for (final rule in rules) {
    if (legadoRuleUsesJs(rule)) {
      throw LegadoException('这本书源用了 JavaScript 规则，当前还不能执行');
    }
  }
}
