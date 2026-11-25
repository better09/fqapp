import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/legado/book_source.dart';
import 'package:fqapp/legado/comic_content.dart';
import 'package:fqapp/legado/comic_history.dart';
import 'package:fqapp/legado/source_check.dart';
import 'package:fqapp/legado/web_book.dart';
import 'package:fqapp/pages/search_book_source.dart';
import 'package:fqapp/services/library_store.dart';

LegadoBookSource _comic({String content = 'img@data-src', String? next}) =>
    LegadoBookSource({
      'bookSourceUrl': 'https://comic.example',
      'bookSourceName': '漫画站',
      'bookSourceType': 2,
      'searchUrl': '/s?k={{key}}',
      'ruleSearch': {'bookList': '.item', 'name': 'a@text', 'bookUrl': 'a@href'},
      'ruleContent': {'content': content, 'nextContentUrl': ?next},
    });

void main() {
  test('image sources are readable and labelled as comics', () {
    final comic = _comic();
    expect(comic.isComic, isTrue);
    expect(comic.readable, isTrue);
    expect(sourceUnusableReason(comic), isNull);
    final audio = LegadoBookSource({...comic.raw, 'bookSourceType': 1});
    expect(audio.readable, isFalse);
    expect(sourceUnusableReason(audio), 'skip');
    final hit = LegadoHit(source: comic, name: '某漫画', bookUrl: 'https://x/1');
    expect(hit.toMediaItem().kind, 'book');
    expect(hit.toMediaItem().badge, '漫画 · 漫画站');
  });

  test('scope menu splits novels and comics only when comics exist', () {
    final text = LegadoBookSource({
      'bookSourceUrl': 'https://text.example',
      'bookSourceName': '小说站',
    });
    expect(
      bookSourceScopeChoices([text]).map((choice) => choice.label),
      ['全部', '校验可用'],
    );
    final sources = [text, _comic()];
    expect(
      bookSourceScopeChoices(sources).map((choice) => choice.label),
      ['全部', '校验可用', '小说', '漫画'],
    );
    expect(sourcesInScope(sources, 't:comic').map((source) => source.name), [
      '漫画站',
    ]);
    expect(sourcesInScope(sources, 't:text').map((source) => source.name), [
      '小说站',
    ]);
  });

  test('image refs come from plain lines, img tags and request options', () {
    expect(
      legadoImageRefs([
        'https://img/1.jpg\n/2.jpg\n不是地址',
        '<img src="https://img/3.jpg"><img data-src="https://img/4.jpg" src="data:x">',
        'https://img/5.jpg,{"headers":{"Referer":"https://r"}}',
      ]),
      [
        'https://img/1.jpg',
        '/2.jpg',
        'https://img/3.jpg',
        'https://img/4.jpg',
        'https://img/5.jpg,{"headers":{"Referer":"https://r"}}',
      ],
    );
  });

  test('chapter images follow next pages and carry referer headers', () async {
    final pages = {
      'https://comic.example/c/1':
          '<div><img data-src="/p/1.jpg"><img data-src="/p/2.jpg">'
          '<a id="next" href="/c/1?p=2">下一页</a></div>',
      'https://comic.example/c/1?p=2':
          '<div><img data-src="/p/2.jpg"><img data-src="/p/3.jpg"></div>',
    };
    final images = await loadLegadoComicImages(
      _comic(next: '#next@href'),
      'https://comic.example/c/1',
      fetch: (request) async {
        final url = request.url.toString();
        return LegadoFetched(pages[url]!, url);
      },
    );
    expect(images.map((image) => image.url), [
      'https://comic.example/p/1.jpg',
      'https://comic.example/p/2.jpg',
      'https://comic.example/p/3.jpg',
    ]);
    expect(images.first.headers['Referer'], 'https://comic.example/c/1');
  });

  test('falls back to page images and fails when none are found', () async {
    final images = await loadLegadoComicImages(
      _comic(content: '.missing@src'),
      'https://comic.example/c/2',
      fetch: (request) async => LegadoFetched(
        '<img src="https://cdn/a.png"><img data-original="https://cdn/b.png">',
        request.url.toString(),
      ),
    );
    expect(images.map((image) => image.url), [
      'https://cdn/a.png',
      'https://cdn/b.png',
    ]);
    await expectLater(
      loadLegadoComicImages(
        _comic(),
        'https://comic.example/c/3',
        fetch: (request) async =>
            LegadoFetched('<p>空</p>', request.url.toString()),
      ),
      throwsA(isA<LegadoException>()),
    );
  });

  test('comic history is stored as the book-source book entry', () async {
    final store = _MemoryStore();
    final history = SourceComicHistory(
      store,
      source: legadoSourceMark,
      seriesId: 'https://comic.example',
      author: '作者',
      chapterCount: 12,
    );
    await history.addHistory({
      'id': 'manga:https://x/1',
      'contentId': 'https://x/1',
      'kind': 'manga',
      'episode': 3,
    });
    final saved = store.entries['https://x/1']!;
    expect(saved['kind'], 'book');
    expect(saved['source'], legadoSourceMark);
    expect(saved['chapterCount'], 12);
    expect(saved['author'], '作者');
    expect(saved['seriesId'], 'https://comic.example');
    expect(saved.containsKey('contentId'), isFalse);
    expect((await history.historyEntry('manga:https://x/1'))?['kind'], 'manga');
    await history.updateProgress('manga:https://x/1', 5, 0.5);
    expect(store.entries['https://x/1']!['episode'], 5);
  });
}

class _MemoryStore implements ReaderStore {
  final entries = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async => entries[id];

  @override
  Future<void> addHistory(Map<String, dynamic> entry) async {
    entries[entry['id'] as String] = Map.of(entry);
  }

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) async {
    entries[id] = {...?entries[id], 'episode': episode, 'progress': progress};
  }

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {}

  @override
  Future<Set<String>> watchedEpisodeIds(String id) async => {};

  @override
  Future<void> markEpisodeWatched(String id, Iterable<String> episodeIds) async {}

  @override
  Future<void> forgetWatchedEpisodes(String id) async {}
}
