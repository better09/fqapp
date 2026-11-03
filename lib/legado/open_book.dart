import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../pages/reader_page.dart';
import '../services/library_store.dart';
import 'book_source.dart';
import 'book_source_store.dart';
import 'web_book.dart';

/// 从书架上的自定义书源条目直接进入阅读器。
Future<void> openLegadoShelfItem(BuildContext context, MediaItem item) async {
  final sourceUrl = item.seriesId;
  if (sourceUrl == null || sourceUrl.isEmpty) {
    _tell(context, '找不到这本书所属的书源');
    return;
  }
  final sources = await HiveBookSourceRepository().load();
  LegadoBookSource? source;
  for (final itemSource in sources) {
    if (itemSource.url == sourceUrl) source = itemSource;
  }
  if (!context.mounted) return;
  if (source == null) {
    _tell(context, '这本书的书源已经被删除');
    return;
  }
  await openLegadoHit(
    context,
    LegadoHit(
      source: source,
      name: item.title,
      bookUrl: item.id,
      author: item.author,
      cover: item.cover,
      intro: item.intro,
    ),
  );
}

/// 拉目录后打开现有阅读器，正文按书源规则现取。
Future<void> openLegadoHit(BuildContext context, LegadoHit hit) async {
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  List<Chapter> chapters;
  try {
    chapters = await loadLegadoChapters(hit);
  } catch (error) {
    if (navigator.mounted) navigator.pop();
    if (context.mounted) _tell(context, '$error');
    return;
  }
  if (!navigator.mounted) return;
  navigator.pop();
  final startIndex = await _rememberChapterCount(hit, chapters.length);
  if (!navigator.mounted) return;
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ReaderPage(
        bookId: hit.bookUrl,
        title: hit.name,
        cover: hit.cover,
        chapters: chapters,
        startIndex: startIndex,
        chapterLoader: (chapter) =>
            loadLegadoContent(hit.source, chapter.itemId),
        shelfItem: hit.toMediaItem(),
      ),
    ),
  );
}

/// 目录一出来就把总章数写进阅读记录，书架不用等翻页才知道共多少章。
/// 已有进度时从那一章接着读，没有进度则不把第 1 章算成已读。
Future<int> _rememberChapterCount(LegadoHit hit, int chapterCount) async {
  if (chapterCount <= 0) return 0;
  try {
    final existing = await LibraryStore.instance.historyEntry(hit.bookUrl);
    final episode = existing?['episode'];
    final start = episode is num && episode >= 0 && episode < chapterCount
        ? episode.toInt()
        : 0;
    await LibraryStore.instance.addHistory({
      ...?existing,
      'id': hit.bookUrl,
      'kind': 'book',
      'title': hit.name,
      'bookId': hit.bookUrl,
      'cover': hit.cover,
      'author': hit.author,
      'source': legadoSourceMark,
      'chapterCount': chapterCount,
      'time': existing?['time'] ?? DateTime.now().millisecondsSinceEpoch,
    });
    return start;
  } catch (_) {
    return 0;
  }
}

void _tell(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
