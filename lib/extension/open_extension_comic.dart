import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../legado/comic_history.dart';
import '../models/chapter_media.dart';
import '../models/media_item.dart';
import '../pages/comic_reader_page.dart';
import '../services/library_store.dart';
import 'comic_extension.dart';

/// 扩展漫画的一页图：先问脚本 `onImageLoad` 怎么取，再由宿主下载或直接用
/// 脚本给出的数据。图片只进内存缓存，和其他漫画页一致。
@immutable
class ExtensionImageProvider extends ImageProvider<ExtensionImageProvider> {
  const ExtensionImageProvider({
    required this.client,
    required this.sourceKey,
    required this.comicId,
    required this.chapter,
    required this.url,
  });

  final ComicExtensionClient client;
  final String sourceKey;
  final String comicId;
  final String chapter;
  final String url;

  @override
  Future<ExtensionImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    ExtensionImageProvider key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: url,
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final request = await client.image(sourceKey, url, comicId, chapter);
    final bytes = await client.fetchImage(request);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is ExtensionImageProvider &&
      other.sourceKey == sourceKey &&
      other.comicId == comicId &&
      other.chapter == chapter &&
      other.url == url;

  @override
  int get hashCode => Object.hash(sourceKey, comicId, chapter, url);
}

/// 从书架、搜索或浏览历史打开一部扩展漫画：拉详情和章节后进漫画阅读器。
Future<void> openExtensionComic(
  BuildContext context,
  MediaItem item, {
  ComicExtensionClient? client,
  ReaderStore? store,
}) async {
  final sourceKey = item.seriesId ?? '';
  if (sourceKey.isEmpty) {
    _tell(context, '找不到这部漫画所属的漫画源');
    return;
  }
  final extensions = client ?? ComicExtensionRuntime.shared;
  final history = store ?? LibraryStore.instance;
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  ExtensionComicDetail detail;
  try {
    detail = await extensions.loadInfo(sourceKey, item.id);
  } catch (error) {
    if (navigator.mounted) navigator.pop();
    if (context.mounted) _tell(context, '$error');
    return;
  }
  if (!navigator.mounted) return;
  navigator.pop();
  final title = detail.title.isEmpty ? item.title : detail.title;
  final cover = detail.cover.isEmpty ? item.cover : detail.cover;
  final author = detail.author.isEmpty ? item.author : detail.author;
  final startIndex = await rememberSourceBook(
    id: item.id,
    title: title,
    cover: cover,
    author: author,
    source: comicExtensionMark,
    seriesId: sourceKey,
    chapterCount: detail.chapters.length,
    store: history,
  );
  if (!navigator.mounted) return;
  final chapterIds = <String, String>{};
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ComicReaderPage(
        bookId: item.id,
        title: title,
        cover: cover,
        chapters: detail.chapters,
        startIndex: startIndex,
        readerStore: SourceComicHistory(
          history,
          source: comicExtensionMark,
          seriesId: sourceKey,
          author: author,
          chapterCount: detail.chapters.length,
        ),
        chapterLoader: (chapter) async {
          final urls = await extensions.loadEpisode(
            sourceKey,
            item.id,
            chapter.itemId,
          );
          for (final url in urls) {
            chapterIds[url] = chapter.itemId;
          }
          return [for (final url in urls) ComicImage(url: url)];
        },
        imageProviderFactory: (image) => ResizeImage(
          ExtensionImageProvider(
            client: extensions,
            sourceKey: sourceKey,
            comicId: item.id,
            chapter: chapterIds[image.url] ?? '',
            url: image.url,
          ),
          width: 2048,
          height: 8192,
          policy: ResizeImagePolicy.fit,
        ),
        shelfItem: item.copyWith(
          title: title,
          cover: cover,
          author: author,
          source: comicExtensionMark,
          seriesId: sourceKey,
        ),
      ),
    ),
  );
}

void _tell(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
