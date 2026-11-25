// 用真实的 QuickJS 跑 Venera 运行时和一个漫画源脚本。
//
// flutter test 进程里没有插件的原生库，需要先编一个宿主版本：
//   cmake <pub-cache>/git/flutter_qjs-<ref>/test && cmake --build .
//   mkdir -p $DIR/flutter_qjs.framework
//   cp libffiquickjs.dylib $DIR/flutter_qjs.framework/flutter_qjs
//   FQ_QJS_HOST_DIR=$DIR flutter test test/comic_extension_engine_test.dart
// 没有设置 FQ_QJS_HOST_DIR 时跳过。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/extension/comic_extension.dart';
import 'package:fqapp/extension/extension_store.dart';
import 'package:fqapp/extension/js_engine.dart';

const _script = r'''
class TestSource extends ComicSource {
  name = "测试源"
  key = "test_src"
  version = "1.0.1"
  minAppVersion = "1.0.0"
  url = "https://repo.example/test_src.js"
  settings = {
    domain: { title: "域名", type: "input", default: "https://comic.example" },
  }

  init() {
    this.saveData("token", Convert.hexEncode(Convert.md5(Convert.encodeUtf8("abc"))))
  }

  search = {
    load: async (keyword, options, page) => {
      const base = this.loadSetting("domain")
      const res = await Network.get(`${base}/search?q=${encodeURIComponent(keyword)}&p=${page}`, {})
      const doc = new HtmlDocument(res.body)
      const comics = doc.querySelectorAll(".item").map((e) => new Comic({
        id: e.attributes["data-id"],
        title: e.querySelector("a").text,
        cover: e.querySelector("img").attributes["src"],
        subtitle: this.loadData("token"),
      }))
      doc.dispose()
      return { comics: comics, maxPage: 1 }
    },
  }

  comic = {
    loadInfo: async (id) => {
      const chapters = new Map()
      chapters.set("c1", "第1话")
      chapters.set("c2", "第2话")
      return new ComicDetails({
        title: "漫画" + id,
        cover: "https://img.example/cover.jpg",
        description: "简介",
        tags: { "作者": ["某人"] },
        chapters: chapters,
      })
    },
    loadEp: async (comicId, epId) => {
      const res = await Network.get(`https://comic.example/ep/${epId}`, {})
      return { images: JSON.parse(res.body) }
    },
    onImageLoad: (url, comicId, epId) => {
      if (url.endsWith(".enc")) {
        return {
          url: url,
          onResponse: (buffer) => Convert.decodeBase64(Convert.decodeUtf8(buffer)),
        }
      }
      return { url: url + "?sig=1", headers: { Referer: "https://comic.example/" + epId } }
    },
  }
}
''';

void main() {
  final hostDir = Platform.environment['FQ_QJS_HOST_DIR'];
  final runtime = File('assets/venera/init.js').readAsStringSync();
  final requests = <http.Request>[];

  late MemoryComicExtensionStore store;
  late ComicExtensionRuntime extensions;

  setUpAll(() {
    if (hostDir != null) Directory.current = hostDir;
  });

  setUp(() {
    requests.clear();
    store = MemoryComicExtensionStore();
    final engine = ComicJsEngine(
      store: store,
      runtime: () async => runtime,
      client: () => MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path == '/search') {
          return http.Response.bytes(
            utf8.encode(
              '<div class="item" data-id="42"><a>漫画甲</a>'
              '<img src="https://img.example/42.jpg"></div>',
            ),
            200,
            headers: {
              'content-type': 'text/html; charset=utf-8',
              'set-cookie': 'sid=abc; Path=/',
            },
          );
        }
        if (path.startsWith('/ep/')) {
          return http.Response(
            jsonEncode(['https://img.example/1.jpg', 'https://img.example/2.enc']),
            200,
          );
        }
        if (path == '/2.enc') {
          return http.Response(base64Encode([1, 2, 3, 4]), 200);
        }
        return http.Response('', 404);
      }),
    );
    extensions = ComicExtensionRuntime(store: store, engine: engine);
  });

  test(
    'installs a Venera source and runs search, details, pages and images',
    () async {
      final installed = await extensions.install(_script);
      expect(installed.key, 'test_src');
      expect(installed.name, '测试源');
      expect(installed.updateUrl, 'https://repo.example/test_src.js');
      expect(store.extensions.single.key, 'test_src');
      expect(
        store.data['test_src']?['token'],
        '900150983cd24fb0d6963f7d28e17f72',
      );

      final found = await extensions.search('test_src', '甲');
      expect(found.single.id, '42');
      expect(found.single.title, '漫画甲');
      expect(found.single.cover, 'https://img.example/42.jpg');
      expect(found.single.subtitle, '900150983cd24fb0d6963f7d28e17f72');
      expect(found.single.toMediaItem().source, comicExtensionMark);
      expect(requests.single.url.queryParameters['q'], '甲');
      expect(store.cookies['comic.example'], {'sid': 'abc'});

      final detail = await extensions.loadInfo('test_src', '42');
      expect(detail.title, '漫画42');
      expect(detail.author, '某人');
      expect(detail.chapters.map((c) => c.itemId), ['c1', 'c2']);
      expect(detail.chapters.map((c) => c.title), ['第1话', '第2话']);

      final pages = await extensions.loadEpisode('test_src', '42', 'c1');
      expect(pages, ['https://img.example/1.jpg', 'https://img.example/2.enc']);
      expect(requests.last.headers['Cookie'], 'sid=abc');

      final plain = await extensions.image('test_src', pages[0], '42', 'c1');
      expect(plain.url, 'https://img.example/1.jpg?sig=1');
      expect(plain.headers['Referer'], 'https://comic.example/c1');
      expect(plain.bytes, isNull);

      final decoded = await extensions.image('test_src', pages[1], '42', 'c1');
      expect(decoded.bytes, [1, 2, 3, 4]);
      expect(await extensions.fetchImage(decoded), [1, 2, 3, 4]);
    },
    skip: hostDir == null ? '没有设置 FQ_QJS_HOST_DIR' : false,
  );

  test(
    'rejects scripts that are not Venera sources or need a newer runtime',
    () async {
      await expectLater(
        extensions.install('console.log("hi")'),
        throwsA(isA<ComicExtensionException>()),
      );
      await expectLater(
        extensions.install(
          _script.replaceFirst('minAppVersion = "1.0.0"', 'minAppVersion = "9.0.0"'),
        ),
        throwsA(isA<ComicExtensionException>()),
      );
      expect(store.extensions, isEmpty);
    },
    skip: hostDir == null ? '没有设置 FQ_QJS_HOST_DIR' : false,
  );

  test('reloads an installed source after the engine restarts', () async {
    await extensions.install(_script);
    final fresh = ComicExtensionRuntime(
      store: store,
      engine: ComicJsEngine(store: store, runtime: () async => runtime),
    );
    final detail = await fresh.loadInfo('test_src', '7');
    expect(detail.title, '漫画7');
  }, skip: hostDir == null ? '没有设置 FQ_QJS_HOST_DIR' : false);
}
