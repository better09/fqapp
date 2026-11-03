import 'dart:async';

import 'package:html/dom.dart';
import 'package:http/http.dart' as http;

import '../models/media_item.dart';
import 'analyze_url.dart';
import 'book_source.dart';
import 'charset.dart';
import 'rules.dart';
import 'visible_text.dart';

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

/// 搜索过程中的进度。命中会随每个书源返回立刻累积，不用等全部结束。
class LegadoSearchProgress {
  final List<LegadoHit> hits;
  final List<String> errors;
  final int finished;
  final int total;

  const LegadoSearchProgress({
    required this.hits,
    required this.errors,
    required this.finished,
    required this.total,
  });

  bool get done => finished >= total;
}

/// 同时查询的书源数。阅读默认也是有限并发，而不是一个书源排队等下一个。
const legadoSearchConcurrency = 8;

const _legadoRequestTimeout = Duration(seconds: 12);

typedef LegadoFetcher = Future<LegadoFetched> Function(LegadoRequest request);

class LegadoFetched {
  final String body;
  final String url;
  const LegadoFetched(this.body, this.url);
}

Future<LegadoFetched> fetchLegado(LegadoRequest request) {
  final client = http.Client();
  final done = Completer<LegadoFetched>();
  final timer = Timer(_legadoRequestTimeout, () {
    client.close();
    if (!done.isCompleted) done.completeError(LegadoException('请求超时'));
  });
  _readLegado(client, request)
      .then(
        (value) {
          if (!done.isCompleted) done.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (done.isCompleted) return;
          done.completeError(
            error is LegadoException ? error : LegadoException('请求失败'),
            stack,
          );
        },
      )
      .whenComplete(() {
        timer.cancel();
        client.close();
      });
  return done.future;
}

Future<LegadoFetched> _readLegado(
  http.Client client,
  LegadoRequest request,
) async {
  final outgoing = http.Request(request.method, request.url)
    ..headers.addAll(request.headers);
  if (request.body != null && request.method != 'GET') {
    outgoing.body = request.body!;
  }
  _attachCookie(outgoing);
  final response = await client.send(outgoing);
  final bytes = await response.stream.toBytes();
  _storeCookies(request.url, response.headers);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw LegadoException('请求失败（${response.statusCode}）');
  }
  final url = response.request?.url.toString() ?? request.url.toString();
  return LegadoFetched(
    decodeLegadoBytes(
      bytes,
      charset: request.charset,
      contentType: response.headers['content-type'],
    ),
    url,
  );
}

final _cookies = <String, Map<String, String>>{};

void _attachCookie(http.Request outgoing) {
  if (outgoing.headers.keys.any((key) => key.toLowerCase() == 'cookie')) {
    return;
  }
  final jar = _cookies[outgoing.url.host];
  if (jar == null || jar.isEmpty) return;
  outgoing.headers['Cookie'] = [
    for (final entry in jar.entries) '${entry.key}=${entry.value}',
  ].join('; ');
}

void _storeCookies(Uri url, Map<String, String> headers) {
  final header = headers.entries
      .where((entry) => entry.key.toLowerCase() == 'set-cookie')
      .map((entry) => entry.value)
      .join(',');
  if (header.isEmpty) return;
  final jar = _cookies.putIfAbsent(url.host, () => {});
  for (final part in header.split(RegExp(r',(?=\s*[^;,=\s]+=)'))) {
    final pair = part.split(';').first.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1).trim();
    if (value.isEmpty) {
      jar.remove(name);
    } else {
      jar[name] = value;
    }
  }
}

Future<LegadoSearchBatch> searchLegadoSources({
  required List<LegadoBookSource> sources,
  required String keyword,
  LegadoFetcher fetch = fetchLegado,
  void Function(LegadoSearchProgress progress)? onProgress,
  bool Function()? isCancelled,
  int concurrency = legadoSearchConcurrency,
}) async {
  final enabled = sources
      .where((item) => item.enabled && item.type == 0)
      .toList();
  final hits = <LegadoHit>[];
  final errors = <String>[];
  var finished = 0;
  var running = 0;
  final waiting = <Completer<void>>[];

  void report() {
    onProgress?.call(
      LegadoSearchProgress(
        hits: List.unmodifiable(hits),
        errors: List.unmodifiable(errors),
        finished: finished,
        total: enabled.length,
      ),
    );
  }

  report();
  Future<void> acquire() async {
    while (running >= concurrency) {
      final slot = Completer<void>();
      waiting.add(slot);
      await slot.future;
    }
    running++;
  }

  void release() {
    running--;
    if (waiting.isNotEmpty) waiting.removeAt(0).complete();
  }

  final tasks = <Future<void>>[];
  for (final source in enabled) {
    if (isCancelled?.call() == true) break;
    await acquire();
    if (isCancelled?.call() == true) {
      release();
      break;
    }
    tasks.add(
      _searchSource(source, keyword, fetch)
          .then(
            (found) {
              if (isCancelled?.call() == true) return;
              hits.addAll(found);
            },
            onError: (Object error, StackTrace _) {
              if (isCancelled?.call() == true) return;
              final message = error is LegadoException
                  ? error.message
                  : '$error';
              errors.add('${source.name}：$message');
            },
          )
          .whenComplete(() {
            release();
            if (isCancelled?.call() == true) return;
            finished++;
            report();
          }),
    );
  }
  if (isCancelled?.call() != true) await Future.wait(tasks);
  return LegadoSearchBatch(List.of(hits), List.of(errors));
}

Future<List<LegadoHit>> _searchSource(
  LegadoBookSource source,
  String keyword,
  LegadoFetcher fetch,
) {
  return _searchOne(source, keyword, fetch).timeout(
    _legadoRequestTimeout,
    onTimeout: () => throw LegadoException('请求超时'),
  );
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
    if (name.isEmpty) continue;
    var url = legadoFirst(node, source.toc.chapterUrl, baseUrl: pageUrl);
    if (!_usableChapterUrl(url)) {
      url = _chapterFallbackUrl(node, pageUrl, chapters.length);
    }
    if (url.isEmpty || !seen.add(url)) continue;
    chapters.add(Chapter(itemId: url, title: name, volumeName: ''));
  }
  return chapters;
}

bool _usableChapterUrl(String url) {
  final lower = url.trim().toLowerCase();
  return lower.isNotEmpty &&
      !lower.startsWith('javascript:') &&
      !lower.startsWith('#');
}

/// 规则没给出可用链接时，从 href、data-href 或 onclick 里找章节地址。
String _chapterFallbackUrl(Object node, String pageUrl, int index) {
  if (node is Element) {
    final found = _chapterLink(node);
    if (found.isNotEmpty) return resolveAgainst(pageUrl, found);
  }
  return '$pageUrl#chapter-$index';
}

String _chapterLink(Element element) {
  final nodes = [element, ...element.querySelectorAll('a')];
  for (final node in nodes) {
    for (final key in ['href', 'data-href', 'data-url', 'data-link']) {
      final value = node.attributes[key]?.trim() ?? '';
      if (_usableChapterUrl(value)) return value;
    }
    final onclick = node.attributes['onclick'] ?? '';
    final match = RegExp(
      r'''['"]((?:https?:)?/[^'"]+|[^'"]+\.s?html[^'"]*)['"]''',
    ).firstMatch(onclick);
    final target = match?.group(1)?.trim() ?? '';
    if (_usableChapterUrl(target)) return target;
  }
  return '';
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
        raw: page.body,
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
  final trimmed = raw.trim();
  if (!trimmed.contains('<')) return trimmed;
  final document = parseLegadoDocument(trimmed);
  if (document is! Element) return trimmed;
  return legadoVisibleText(document);
}

LegadoRequest _get(String url, LegadoBookSource source) {
  final headers = Map<String, String>.from(source.headers);
  final hasReferer = headers.keys.any((key) => key.toLowerCase() == 'referer');
  if (!hasReferer && source.url.startsWith('http')) {
    headers['Referer'] = source.url;
  }
  return analyzeLegadoUrl(url, base: source.url, headers: headers);
}

void _rejectJs(List<String?> rules) {
  for (final rule in rules) {
    if (legadoRuleUsesJs(rule)) {
      throw LegadoException('这本书源用了 JavaScript 规则，当前还不能执行');
    }
  }
}
