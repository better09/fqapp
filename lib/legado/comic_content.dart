import 'package:html/dom.dart';
import 'package:html/parser.dart';

import '../models/chapter_media.dart';
import 'analyze_url.dart';
import 'book_source.dart';
import 'rules.dart';
import 'web_book.dart';

/// 一章漫画最多跟多少页「下一页」，防止站点分页死循环。
const _maxComicPages = 30;

const _lazyImageAttributes = [
  'data-original',
  'data-src',
  'data-lazy-src',
  'data-echo',
  'src',
];

/// 按图片书源（`bookSourceType: 2`）的正文规则取出一章的图片，顺序即阅读顺序。
///
/// 正文规则可以直接给出图片地址（每行一个，或 JSON 列表），也可以给出带
/// `<img>` 的 HTML。规则一张图都没选出时，退回到整页里的 `<img>`。
/// 图片地址后面可以跟阅读的 `,{"headers":{...}}` 请求选项。
Future<List<ComicImage>> loadLegadoComicImages(
  LegadoBookSource source,
  String chapterUrl, {
  LegadoFetcher fetch = fetchLegado,
}) async {
  rejectLegadoJs([source.content.content, source.content.nextContentUrl]);
  final images = <ComicImage>[];
  final seen = <String>{};
  final visited = <String>{chapterUrl};
  var url = chapterUrl;
  for (var hop = 0; hop < _maxComicPages; hop++) {
    final page = await fetch(legadoPageRequest(url, source));
    final document = parseLegadoDocument(page.body);
    var refs = legadoImageRefs(
      legadoTexts(
        document,
        source.content.content,
        baseUrl: page.url,
        raw: page.body,
      ),
    );
    if (refs.isEmpty && document is Element) refs = _imagesIn(document);
    for (final ref in refs) {
      final image = _comicImage(ref, page.url, source);
      if (image != null && seen.add(image.url)) images.add(image);
    }
    final next = legadoFirst(
      document,
      source.content.nextContentUrl,
      baseUrl: page.url,
    );
    if (next.isEmpty || !visited.add(next)) break;
    url = next;
  }
  if (images.isEmpty) throw LegadoException('本章没有解析到图片');
  return images;
}

/// 从正文规则的结果里拆出图片地址（可能带请求选项），保持原有顺序。
List<String> legadoImageRefs(List<String> values) {
  final refs = <String>[];
  for (final value in values) {
    final text = value.trim();
    if (text.isEmpty) continue;
    if (text.toLowerCase().contains('<img')) {
      refs.addAll(_imagesIn(parseFragment(text)));
      continue;
    }
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final ref = line.trim();
      if (_looksLikeImageRef(ref)) refs.add(ref);
    }
  }
  return refs;
}

List<String> _imagesIn(Node root) {
  final List<Element> elements;
  if (root is Element) {
    elements = root.querySelectorAll('img');
  } else if (root is DocumentFragment) {
    elements = root.querySelectorAll('img');
  } else {
    elements = const [];
  }
  final refs = <String>[];
  for (final element in elements) {
    for (final attribute in _lazyImageAttributes) {
      final value = element.attributes[attribute]?.trim() ?? '';
      if (value.isNotEmpty && !value.startsWith('data:')) {
        refs.add(value);
        break;
      }
    }
  }
  return refs;
}

bool _looksLikeImageRef(String ref) {
  if (ref.isEmpty || (ref.contains(' ') && !ref.contains(',{'))) return false;
  final lower = ref.toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('//') ||
      lower.startsWith('/');
}

ComicImage? _comicImage(String ref, String pageUrl, LegadoBookSource source) {
  final headers = Map<String, String>.from(source.headers);
  if (!headers.keys.any((key) => key.toLowerCase() == 'referer')) {
    headers['Referer'] = pageUrl;
  }
  final LegadoRequest request;
  try {
    request = analyzeLegadoUrl(ref, base: pageUrl, headers: headers);
  } catch (_) {
    return null;
  }
  final scheme = request.url.scheme;
  if (scheme != 'http' && scheme != 'https') return null;
  return ComicImage(url: request.url.toString(), headers: request.headers);
}
