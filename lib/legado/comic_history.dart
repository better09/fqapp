import '../services/library_store.dart';

/// 书源/扩展漫画的阅读记录落在和书源小说同一种记录上（`id` 是这本书自己的
/// 标识、`kind` 是 book），书架和浏览历史因此按小说一样显示进度与章节数。
///
/// 漫画阅读器总会套一层 `manga:` 作用域，这里把它还原回书的标识，同时补上
/// 来源标记、作者、总章数和所属书源，避免整条覆盖时把这些字段写丢。
class SourceComicHistory implements ReaderStore {
  SourceComicHistory(
    this.delegate, {
    required this.source,
    required this.seriesId,
    required this.author,
    required this.chapterCount,
  }) {
    ReadingDataWriteGuard.shareScope(this, delegate);
  }

  final ReaderStore delegate;
  final String source;
  final String seriesId;
  final String author;
  final int chapterCount;

  static const _scope = 'manga:';

  String _bookId(String id) =>
      id.startsWith(_scope) ? id.substring(_scope.length) : id;

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async {
    final saved = await delegate.historyEntry(_bookId(id));
    if (saved == null) return null;
    return {...saved, 'kind': 'manga'};
  }

  @override
  Future<void> addHistory(Map<String, dynamic> entry) {
    final id = _bookId(entry['id']?.toString() ?? '');
    if (id.isEmpty) return Future.value();
    return delegate.addHistory({
      ...Map<String, dynamic>.from(entry)..remove('contentId'),
      'id': id,
      'bookId': id,
      'kind': 'book',
      'author': author,
      'source': source,
      'seriesId': seriesId,
      'chapterCount': chapterCount,
    });
  }

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) => delegate.updateProgress(
    _bookId(id),
    episode,
    progress,
    chapterId: chapterId,
    position: position,
    maxScroll: maxScroll,
  );

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) => delegate.accumulateReadTime(_bookId(bookId), 'book', seconds, at: at);

  @override
  Future<Set<String>> watchedEpisodeIds(String id) =>
      delegate.watchedEpisodeIds(_bookId(id));

  @override
  Future<void> markEpisodeWatched(String id, Iterable<String> episodeIds) =>
      delegate.markEpisodeWatched(_bookId(id), episodeIds);

  @override
  Future<void> forgetWatchedEpisodes(String id) =>
      delegate.forgetWatchedEpisodes(_bookId(id));
}

/// 目录一出来就把总章数写进阅读记录，书架不用等翻页才知道共多少章。
/// 已有进度时返回那一章接着读，没有进度则不把第 1 章算成已读。
Future<int> rememberSourceBook({
  required String id,
  required String title,
  required String cover,
  required String author,
  required String source,
  required String seriesId,
  required int chapterCount,
  ReaderStore? store,
}) async {
  if (chapterCount <= 0) return 0;
  final target = store ?? LibraryStore.instance;
  try {
    final existing = await target.historyEntry(id);
    final episode = existing?['episode'];
    final start = episode is num && episode >= 0 && episode < chapterCount
        ? episode.toInt()
        : 0;
    await target.addHistory({
      ...?existing,
      'id': id,
      'kind': 'book',
      'title': title,
      'bookId': id,
      'cover': cover,
      'author': author,
      'source': source,
      'seriesId': seriesId,
      'chapterCount': chapterCount,
      'time': existing?['time'] ?? DateTime.now().millisecondsSinceEpoch,
    });
    return start;
  } catch (_) {
    return 0;
  }
}
