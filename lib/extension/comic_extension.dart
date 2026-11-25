import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../legado/book_source.dart' show comicExtensionMark;
import '../models/media_item.dart';
import 'extension_store.dart';
import 'js_engine.dart';

export '../legado/book_source.dart' show comicExtensionMark;

class ComicExtensionException implements Exception {
  ComicExtensionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 搜索结果里的一部漫画。
class ExtensionComic {
  const ExtensionComic({
    required this.sourceKey,
    required this.sourceName,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.cover = '',
    this.description = '',
  });

  final String sourceKey;
  final String sourceName;
  final String id;
  final String title;
  final String subtitle;
  final String cover;
  final String description;

  MediaItem toMediaItem() => MediaItem(
    id: id,
    title: title,
    cover: cover,
    author: subtitle,
    badge: '漫画 · $sourceName',
    ep: '',
    kind: 'book',
    intro: description,
    seriesId: sourceKey,
    source: comicExtensionMark,
  );
}

class ExtensionComicDetail {
  const ExtensionComicDetail({
    required this.title,
    required this.chapters,
    this.cover = '',
    this.author = '',
    this.description = '',
  });

  final String title;
  final String cover;
  final String author;
  final String description;

  /// 没有章节表的漫画只有一章，`itemId` 为空串，取图时按 `null` 传给脚本。
  final List<Chapter> chapters;
}

/// 取一张图的方式：脚本已经给出图片数据，或给出请求让宿主去取。
class ExtensionImageRequest {
  const ExtensionImageRequest({
    this.url = '',
    this.method = 'GET',
    this.headers = const {},
    this.data,
    this.bytes,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final Object? data;
  final Uint8List? bytes;
}

/// 页面用到的扩展能力。测试里换成假实现，不必加载 QuickJS。
abstract class ComicExtensionClient {
  Future<List<InstalledComicExtension>> installed();
  Future<InstalledComicExtension> install(String script, {String updateUrl});
  Future<void> remove(String key);
  Future<void> setEnabled(String key, bool enabled);
  Future<List<ExtensionComic>> search(String key, String keyword);
  Future<ExtensionComicDetail> loadInfo(String key, String comicId);
  Future<List<String>> loadEpisode(String key, String comicId, String chapter);
  Future<ExtensionImageRequest> image(
    String key,
    String url,
    String comicId,
    String chapter,
  );
  Future<Uint8List> fetchImage(ExtensionImageRequest request);
}

const _jsonHelper = r'''
globalThis.__fqJson = (value) => JSON.stringify(value === undefined ? null : value,
  (k, v) => v instanceof Map ? Object.fromEntries(v) : v);
''';

/// 用一个共享的 [ComicJsEngine] 跑已安装的 Venera 漫画源脚本。
class ComicExtensionRuntime implements ComicExtensionClient {
  ComicExtensionRuntime({required this.store, ComicJsEngine? engine})
    : engine = engine ?? ComicJsEngine(store: store);

  static ComicExtensionRuntime? _shared;
  static ComicExtensionRuntime get shared =>
      _shared ??= ComicExtensionRuntime(store: HiveComicExtensionStore());

  final ComicExtensionStore store;
  final ComicJsEngine engine;
  final _loaded = <String, Future<void>>{};
  Future<void>? _helpers;

  Future<void> _ready() => _helpers ??= () async {
    await engine.ready();
    engine.run(_jsonHelper, name: '<fqapp-json>');
  }();

  @override
  Future<List<InstalledComicExtension>> installed() => store.loadExtensions();

  @override
  Future<InstalledComicExtension> install(
    String script, {
    String updateUrl = '',
  }) async {
    final meta = await _register(script);
    final installed = InstalledComicExtension(
      key: meta.key,
      name: meta.name,
      version: meta.version,
      script: script,
      updateUrl: meta.url.isNotEmpty ? meta.url : updateUrl,
    );
    final items = [...await store.loadExtensions()]
      ..removeWhere((item) => item.key == meta.key)
      ..add(installed);
    await store.saveExtensions(items);
    _loaded[meta.key] = Future.value();
    return installed;
  }

  @override
  Future<void> remove(String key) async {
    final items = [...await store.loadExtensions()]
      ..removeWhere((item) => item.key == key);
    await store.saveExtensions(items);
    await store.deleteData(key);
    if (_loaded.remove(key) != null) engine.detach(key);
  }

  @override
  Future<void> setEnabled(String key, bool enabled) async {
    final items = [
      for (final item in await store.loadExtensions())
        item.key == key ? item.copyWith(enabled: enabled) : item,
    ];
    await store.saveExtensions(items);
  }

  Future<void> _ensure(String key) => _loaded[key] ??= () async {
    final items = await store.loadExtensions();
    final found = items.where((item) => item.key == key).firstOrNull;
    if (found == null) throw ComicExtensionException('漫画源 $key 未安装');
    await _register(found.script);
  }().catchError((Object error) {
    _loaded.remove(key);
    throw error;
  });

  Future<({String key, String name, String version, String url})> _register(
    String script,
  ) async {
    await _ready();
    final js = script.replaceAll('\r\n', '\n');
    final header = js
        .split('\n')
        .map((line) => line.trim())
        .where(
          (line) =>
              line.startsWith('class ') && line.contains('extends ComicSource'),
        )
        .firstOrNull;
    if (header == null) {
      throw ComicExtensionException('不是 Venera 漫画源脚本（找不到 extends ComicSource）');
    }
    final className = header.substring(6).split('extends').first.trim();
    _guard(
      () => engine.run(
        '(() => { $js\n globalThis.__fqTemp = new $className(); }).call()',
        name: className,
      ),
    );
    final meta = jsonDecode(
      engine.run(
        '__fqJson({name: __fqTemp.name, key: __fqTemp.key, '
        'version: __fqTemp.version, url: __fqTemp.url, '
        'minAppVersion: __fqTemp.minAppVersion, '
        'settings: __fqTemp.settings})',
      ),
    ) as Map<String, dynamic>;
    final key = '${meta['key'] ?? ''}';
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(key)) {
      throw ComicExtensionException('漫画源 key 不合法：$key');
    }
    final minVersion = '${meta['minAppVersion'] ?? ''}';
    if (minVersion.isNotEmpty &&
        compareVersions(minVersion, veneraCompatibleVersion) > 0) {
      throw ComicExtensionException('需要 Venera $minVersion 以上的运行时');
    }
    engine.run(
      'ComicSource.sources[${jsonEncode(key)}] = __fqTemp; '
      'delete globalThis.__fqTemp;',
    );
    final settings = meta['settings'];
    await engine.attachData(
      key,
      settings is Map ? Map<String, dynamic>.from(settings) : const {},
    );
    if (_exists(key, 'init')) {
      try {
        await engine
            .callSource(key, 'init', const [])
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // 初始化失败（例如需要登录）不妨碍安装，用到时再报错。
      }
    }
    final name = '${meta['name'] ?? ''}';
    return (
      key: key,
      name: name.isEmpty ? key : name,
      version: '${meta['version'] ?? ''}',
      url: '${meta['url'] ?? ''}',
    );
  }

  bool _exists(String key, String path) =>
      engine.run(
        'typeof ComicSource.sources[${jsonEncode(key)}]'
        '?.${path.split('.').join('?.')} === "function"',
      ) ==
      true;

  Future<dynamic> _call(String key, String path, List<Object?> args) async {
    await _ensure(key);
    final call =
        'ComicSource.sources[${jsonEncode(key)}].$path'
        '(${args.map(jsonEncode).join(', ')})';
    final raw = await _guardAsync(
      () => engine.evaluate(
        'Promise.resolve($call).then(__fqJson)',
        name: '<$key.$path>',
      ),
    );
    return raw is String ? jsonDecode(raw) : raw;
  }

  @override
  Future<List<ExtensionComic>> search(String key, String keyword) async {
    await _ensure(key);
    final source = jsonEncode(key);
    final options = jsonDecode(
      engine.run(
        '__fqJson((ComicSource.sources[$source].search?.optionList || [])'
        '.map(o => o.default ?? String((o.options || [""])[0]).split("-")[0]))',
      ),
    );
    final result = _exists(key, 'search.load')
        ? await _call(key, 'search.load', [keyword, options, 1])
        : await _call(key, 'search.loadNext', [keyword, options, null]);
    final comics = result is Map ? result['comics'] : null;
    if (comics is! List) return const [];
    final name = await _nameOf(key);
    return [
      for (final comic in comics)
        if (comic is Map && '${comic['id'] ?? ''}'.isNotEmpty)
          ExtensionComic(
            sourceKey: key,
            sourceName: name,
            id: '${comic['id']}',
            title: '${comic['title'] ?? ''}',
            subtitle: '${comic['subtitle'] ?? comic['subTitle'] ?? ''}',
            cover: '${comic['cover'] ?? ''}',
            description: '${comic['description'] ?? ''}',
          ),
    ];
  }

  Future<String> _nameOf(String key) async {
    final items = await store.loadExtensions();
    return items.where((item) => item.key == key).firstOrNull?.name ?? key;
  }

  @override
  Future<ExtensionComicDetail> loadInfo(String key, String comicId) async {
    final info = await _call(key, 'comic.loadInfo', [comicId]);
    if (info is! Map) throw ComicExtensionException('漫画详情格式不对');
    return comicDetailFromJson(Map<String, dynamic>.from(info));
  }

  @override
  Future<List<String>> loadEpisode(
    String key,
    String comicId,
    String chapter,
  ) async {
    final result = await _call(key, 'comic.loadEp', [
      comicId,
      chapter.isEmpty ? null : chapter,
    ]);
    final images = result is Map ? result['images'] : null;
    if (images is! List) throw ComicExtensionException('本章没有图片');
    return [for (final image in images) '$image'];
  }

  @override
  Future<ExtensionImageRequest> image(
    String key,
    String url,
    String comicId,
    String chapter,
  ) async {
    await _ensure(key);
    final args = [key, url, comicId, chapter.isEmpty ? null : chapter];
    final result = await _guardAsync(
      () => engine.evaluate('__fqImage(${args.map(jsonEncode).join(', ')})'),
    );
    if (result is Map && result['bytes'] is Uint8List) {
      return ExtensionImageRequest(bytes: result['bytes'] as Uint8List);
    }
    final request = result is Map ? result['request'] : null;
    if (request is! Map) return ExtensionImageRequest(url: url);
    final headers = request['headers'];
    return ExtensionImageRequest(
      url: '${request['url'] ?? url}',
      method: '${request['method'] ?? 'GET'}',
      headers: {
        if (headers is Map)
          for (final entry in headers.entries) '${entry.key}': '${entry.value}',
      },
      data: request['data'],
    );
  }

  @override
  Future<Uint8List> fetchImage(ExtensionImageRequest request) async {
    final ready = request.bytes;
    if (ready != null) return ready;
    await engine.ready();
    final response = await engine.httpBridge.send({
      'url': request.url,
      'http_method': request.method,
      'headers': request.headers,
      'data': request.data,
      'bytes': true,
    });
    final status = response['status'];
    final body = response['body'];
    if (response['error'] != null || body is! Uint8List) {
      throw ComicExtensionException('${response['error'] ?? '图片加载失败'}');
    }
    if (status is int && status >= 400) {
      throw ComicExtensionException('图片加载失败（HTTP $status）');
    }
    return body;
  }
}

T _guard<T>(T Function() action) {
  try {
    return action();
  } catch (error) {
    throw ComicExtensionException('$error');
  }
}

Future<T> _guardAsync<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on ComicExtensionException {
    rethrow;
  } catch (error) {
    throw ComicExtensionException('$error');
  }
}

/// `comic.loadInfo` 的结果：章节可以是平铺的 `{id: 标题}`，也可以按卷分组。
ExtensionComicDetail comicDetailFromJson(Map<String, dynamic> json) {
  final title = '${json['title'] ?? ''}';
  final chapters = <Chapter>[];
  final raw = json['chapters'];
  if (raw is Map) {
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is Map) {
        for (final inner in value.entries) {
          chapters.add(
            Chapter(
              itemId: '${inner.key}',
              title: '${inner.value}',
              volumeName: '${entry.key}',
            ),
          );
        }
      } else {
        chapters.add(
          Chapter(itemId: '${entry.key}', title: '$value', volumeName: ''),
        );
      }
    }
  }
  if (chapters.isEmpty) {
    chapters.add(Chapter(itemId: '', title: title, volumeName: ''));
  }
  return ExtensionComicDetail(
    title: title,
    cover: '${json['cover'] ?? ''}',
    author: _author(json),
    description: '${json['description'] ?? ''}',
    chapters: chapters,
  );
}

String _author(Map<String, dynamic> json) {
  final subtitle = json['subtitle'] ?? json['subTitle'];
  if (subtitle is String && subtitle.isNotEmpty) return subtitle;
  final tags = json['tags'];
  if (tags is! Map) return '';
  for (final name in const ['作者', 'Author', 'Authors', 'Artist', 'author']) {
    final value = tags[name];
    if (value is List && value.isNotEmpty) return value.join(' / ');
    if (value is String && value.isNotEmpty) return value;
  }
  return '';
}

/// 比较 `1.2.3` 形式的版本号；非数字段按 0 处理。
int compareVersions(String a, String b) {
  List<int> parts(String text) => text
      .split('-')
      .first
      .split('.')
      .map((part) => int.tryParse(part.trim()) ?? 0)
      .toList();
  final left = parts(a);
  final right = parts(b);
  for (var i = 0; i < left.length || i < right.length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}
