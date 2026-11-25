import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/extension/comic_extension.dart';
import 'package:fqapp/extension/extension_repo.dart';
import 'package:fqapp/extension/extension_store.dart';
import 'package:fqapp/extension/open_extension_comic.dart';
import 'package:fqapp/extension/js_http.dart';
import 'package:fqapp/legado/book_source.dart';
import 'package:fqapp/legado/web_book.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/comic_reader_page.dart';
import 'package:fqapp/pages/comic_extensions_page.dart';
import 'package:fqapp/pages/search_book_source.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';

const _script = 'class Demo extends ComicSource { key = "demo" }';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'search_list_view': false}),
  );

  test('repo index resolves file names against the index address', () {
    final entries = parseExtensionRepo(
      '[{"name":"甲","fileName":"a.js","version":"1.2.0"},'
      '{"name":"乙","url":"https://cdn.example/b.js"},{"name":"坏"}]',
      Uri.parse('https://repo.example/configs/index.json'),
    );
    expect(entries.map((entry) => entry.scriptUrl), [
      'https://repo.example/configs/a.js',
      'https://cdn.example/b.js',
    ]);
    expect(entries.first.fileKey, 'a');
    const installed = InstalledComicExtension(
      key: 'a',
      name: '甲',
      version: '1.0.0',
      script: _script,
    );
    expect(entries.first.installedIn([installed]), same(installed));
    expect(compareVersions('1.2.0', '1.10.0'), lessThan(0));
    expect(compareVersions('1.4.3', '1.4.3'), 0);
  });

  test('comic details accept flat, grouped and missing chapter tables', () {
    final flat = comicDetailFromJson({
      'title': '甲',
      'chapters': {'1': '第一话', '2': '第二话'},
      'tags': {
        '作者': ['某人', '另一人'],
      },
    });
    expect(flat.chapters.map((c) => c.itemId), ['1', '2']);
    expect(flat.author, '某人 / 另一人');
    final grouped = comicDetailFromJson({
      'title': '乙',
      'subtitle': '作者乙',
      'chapters': {
        '单行本': {'v1': '第1卷'},
        '连载': {'c1': '第1话'},
      },
    });
    expect(grouped.chapters.map((c) => c.volumeName), ['单行本', '连载']);
    expect(grouped.author, '作者乙');
    final single = comicDetailFromJson({'title': '丙'});
    expect(single.chapters.single.itemId, '');
    expect(single.chapters.single.title, '丙');
  });

  test('cookie jar keeps set-cookie values per domain', () {
    final saved = <Map<String, Map<String, String>>>[];
    final jar = JsCookieJar(null, saved.add);
    final uri = Uri.parse('https://www.comic.example/a');
    jar.absorb(
      uri,
      'sid=1; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT,'
      'token=a=b; Domain=.comic.example',
    );
    expect(jar.snapshot['www.comic.example'], {'sid': '1'});
    expect(jar.snapshot['comic.example'], {'token': 'a=b'});
    expect(jar.header(uri), contains('token=a=b'));
    expect(jar.header(Uri.parse('https://img.comic.example/')), 'token=a=b');
    expect(saved, isNotEmpty);
  });

  test('extension comics keep their own shelf slot per comic', () {
    const comic = ExtensionComic(
      sourceKey: 'demo',
      sourceName: '演示源',
      id: 'c-1',
      title: '漫画',
    );
    final item = comic.toMediaItem();
    expect(item.badge, '漫画 · 演示源');
    expect(isCustomSourceMark(item.source), isTrue);
    expect(ShelfStore.contentIdOf(item), 'c-1');
  });

  test('scope menu counts installed extensions as comic sources', () {
    final session = BookSourceSearchSession()
      ..catalog = [_text()]
      ..extensions = const [_demo];
    expect(session.choices.map((choice) => choice.label), [
      '全部',
      '校验可用',
      '小说',
      '漫画',
    ]);
    expect(session.selectedExtensions, [_demo]);
    session.scopeId = 't:text';
    expect(session.selectedExtensions, isEmpty);
    session.scopeId = 'ok';
    expect(session.selectedExtensions, isEmpty);
  });

  testWidgets('book source search merges extension comics after books', (
    tester,
  ) async {
    final client = _FakeClient()..items = [_demo];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          searchLoader:
              (_, {required int tabType, required int offset}) async =>
                  const [],
          bookSourceCatalog: () async => [_text()],
          bookSourceQuery: ({required sources, required keyword}) async =>
              LegadoSearchBatch([
                LegadoHit(
                  source: sources.first,
                  name: '$keyword苍穹',
                  bookUrl: 'https://text.example/1',
                ),
              ], const []),
          comicExtensions: client,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-source-book')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '斗破');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(client.searches, ['demo:斗破']);
    expect(find.text('斗破苍穹'), findsOneWidget);
    expect(find.text('斗破漫画'), findsOneWidget);

    await tester.tap(find.byKey(const Key('search-book-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小说').last);
    await tester.pumpAndSettle();
    expect(find.text('斗破苍穹'), findsOneWidget);
    expect(find.text('斗破漫画'), findsNothing);
    expect(client.searches, ['demo:斗破']);
  });

  testWidgets('opening an extension comic resumes in the comic reader', (
    tester,
  ) async {
    final client = _FakeClient();
    final history = _History2()
      ..records['m-1'] = {'id': 'm-1', 'kind': 'book', 'episode': 1};
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => openExtensionComic(
              context,
              const ExtensionComic(
                sourceKey: 'demo',
                sourceName: '演示源',
                id: 'm-1',
                title: '旧标题',
              ).toMediaItem(),
              client: client,
              store: history,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    final reader = tester.widget<ComicReaderPage>(find.byType(ComicReaderPage));
    expect(reader.title, '漫画详情');
    expect(reader.startIndex, 1);
    expect(client.episodes, ['demo:m-1:c2']);
    expect(client.images, ['demo:p1.jpg:c2']);
    final saved = history.records['m-1']!;
    expect(saved['source'], comicExtensionMark);
    expect(saved['seriesId'], 'demo');
    expect(saved['chapterCount'], 2);
    expect(saved['author'], '画师');
    expect(tester.takeException(), isNull);
  });

  testWidgets('extension page imports scripts and installs from a repo', (
    tester,
  ) async {
    final client = _FakeClient();
    final store = MemoryComicExtensionStore();
    final fetched = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ComicExtensionsPage(
          client: client,
          store: store,
          fetch: (url) async {
            fetched.add('$url');
            if (url.path.endsWith('index.json')) {
              return '[{"name":"仓库源","fileName":"repo_src.js","version":"2.0.0"}]';
            }
            return _script;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('不内置任何仓库和漫画源'), findsOneWidget);

    await tester.tap(find.byKey(const Key('extension-import')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('extension-input')), _script);
    await tester.tap(find.byKey(const Key('extension-input-ok')));
    await tester.pumpAndSettle();
    expect(client.scripts, [_script]);
    expect(find.text('演示源'), findsOneWidget);

    await tester.tap(find.byKey(const Key('extension-add-repo')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('extension-input')),
      'https://repo.example/index.json',
    );
    await tester.tap(find.byKey(const Key('extension-input-ok')));
    await tester.pumpAndSettle();
    expect(store.repos, ['https://repo.example/index.json']);

    await tester.tap(find.text('https://repo.example/index.json'));
    await tester.pumpAndSettle();
    expect(find.text('仓库源'), findsOneWidget);
    await tester.tap(find.byKey(const Key('repo-install-repo_src')));
    await tester.pumpAndSettle();
    expect(fetched.last, 'https://repo.example/repo_src.js');
    expect(client.updateUrls.last, 'https://repo.example/repo_src.js');
  });
}

const _demo = InstalledComicExtension(
  key: 'demo',
  name: '演示源',
  version: '1.0.0',
  script: _script,
);

LegadoBookSource _text() => LegadoBookSource({
  'bookSourceUrl': 'https://text.example',
  'bookSourceName': '小说站',
  'enabled': true,
});

class _FakeClient implements ComicExtensionClient {
  List<InstalledComicExtension> items = [];
  final scripts = <String>[];
  final updateUrls = <String>[];
  final searches = <String>[];
  final episodes = <String>[];
  final images = <String>[];

  @override
  Future<List<InstalledComicExtension>> installed() async => items;

  @override
  Future<InstalledComicExtension> install(
    String script, {
    String updateUrl = '',
  }) async {
    scripts.add(script);
    updateUrls.add(updateUrl);
    final installed = InstalledComicExtension(
      key: 'demo',
      name: '演示源',
      version: '1.0.0',
      script: script,
      updateUrl: updateUrl,
    );
    items = [installed];
    return installed;
  }

  @override
  Future<void> remove(String key) async => items = [];

  @override
  Future<void> setEnabled(String key, bool enabled) async {}

  @override
  Future<List<ExtensionComic>> search(String key, String keyword) async {
    searches.add('$key:$keyword');
    return [
      ExtensionComic(
        sourceKey: key,
        sourceName: '演示源',
        id: 'm-1',
        title: '$keyword漫画',
      ),
    ];
  }

  @override
  Future<ExtensionComicDetail> loadInfo(String key, String comicId) async =>
      ExtensionComicDetail(
        title: '漫画详情',
        author: '画师',
        chapters: [
          Chapter(itemId: 'c1', title: '第1话', volumeName: ''),
          Chapter(itemId: 'c2', title: '第2话', volumeName: ''),
        ],
      );

  @override
  Future<List<String>> loadEpisode(
    String key,
    String comicId,
    String chapter,
  ) async {
    episodes.add('$key:$comicId:$chapter');
    return ['p1.jpg'];
  }

  @override
  Future<ExtensionImageRequest> image(
    String key,
    String url,
    String comicId,
    String chapter,
  ) async {
    images.add('$key:$url:$chapter');
    return ExtensionImageRequest(
      bytes: img.encodePng(img.Image(width: 4, height: 6)),
    );
  }

  @override
  Future<Uint8List> fetchImage(ExtensionImageRequest request) async =>
      request.bytes!;
}

class _History2 implements ReaderStore {
  final records = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async => records[id];

  @override
  Future<void> addHistory(Map<String, dynamic> entry) async {
    records['${entry['id']}'] = Map.of(entry);
  }

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) async {}

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
