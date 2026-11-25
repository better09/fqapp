part of 'search_page.dart';

extension _BookSourceSearch on _SearchPageState {
  Future<void> _executeSearch(String query, {required bool asKeyword}) async {
    _rememberQuery(query);
    ++_requestGeneration;
    // 联想词点下去执行的是另一条查询，草稿要跟着走，否则联想层会盖住结果。
    ++_suggestGeneration;
    _rebuild(() {
      _query = query;
      _draft = query;
      _suggestions = const [];
      // 书旗和书源的 id 都不是番茄作品 id。
      _idQuery = (!_fanqieSource || asKeyword)
          ? null
          : mediaIdFromSearch(query);
      _feeds = [for (final _ in _SearchPageState._categories) _SearchFeed()];
    });
    if (_shuqiSource) {
      _activeRequest?.cancel();
      await _searchShuqi(query, _requestGeneration);
      return;
    }
    if (_bookSourceMode) {
      _activeRequest?.cancel();
      await _searchBookSources(query, _requestGeneration);
      return;
    }
    await _loadTab(_tabIndex);
  }

  Future<void> _loadBookSourceCatalog() {
    if (_bookSources.loaded) return Future<void>.value();
    return _bookSourceCatalogLoad ??= _readBookSourceCatalog();
  }

  ComicExtensionClient? get _comicExtensions =>
      widget.comicExtensions ??
      (widget.bookSourceCatalog == null ? ComicExtensionRuntime.shared : null);

  Future<void> _readBookSourceCatalog() async {
    try {
      final catalog =
          await (widget.bookSourceCatalog ?? loadStoredBookSources)();
      final extensions = await _comicExtensions?.installed() ?? const [];
      if (!mounted) return;
      _rebuild(() {
        _bookSources.catalog = catalog;
        _bookSources.extensions = [
          for (final extension in extensions)
            if (extension.enabled) extension,
        ];
        _bookSources.loaded = true;
      });
    } catch (_) {
      _bookSourceCatalogLoad = null;
    }
  }

  void _selectBookScope(int index) {
    final choices = _bookSources.choices;
    if (index < 0 || index >= choices.length) return;
    if (choices[index].id == _bookSources.scopeId) return;
    _rebuild(() {
      _bookSources.scopeId = choices[index].id;
      _feeds = [for (final _ in _SearchPageState._categories) _SearchFeed()];
    });
    ++_requestGeneration;
    if (_query.isEmpty) return;
    unawaited(_searchBookSources(_query, _requestGeneration));
  }

  /// 按当前范围同时查已启用的小说和漫画书源，每返回一个书源就刷新一次结果。
  Future<void> _searchBookSources(String query, int generation) async {
    final feed = _feeds[0];
    _rebuild(() {
      feed.loading = true;
      feed.error = null;
    });
    try {
      if (!_bookSources.loaded) {
        await _loadBookSourceCatalog();
        if (!mounted || generation != _requestGeneration) return;
      }
      final sources = _bookSources.selected;
      final extensions = _bookSources.selectedExtensions;
      if (sources.isEmpty && extensions.isEmpty) {
        _rebuild(() {
          feed.items.clear();
          feed.initialized = true;
          feed.loading = false;
          feed.hasMore = false;
        });
        return;
      }
      final merged = _MergedSourceSearch(
        (items, errors, done, finished, total) => _applyBookHits(
          feed,
          items,
          errors,
          done: done,
          finished: finished,
          total: total,
        ),
        hasBooks: sources.isNotEmpty,
        hasComics: extensions.isNotEmpty,
      );
      bool cancelled() => !mounted || generation != _requestGeneration;
      await Future.wait([
        if (extensions.isNotEmpty)
          searchComicExtensions(
            client: _comicExtensions!,
            extensions: extensions,
            keyword: query,
            isCancelled: cancelled,
            onProgress: merged.comics,
          ).then((progress) {
            if (!cancelled()) merged.comicsDone(progress);
          }),
        if (sources.isNotEmpty && widget.bookSourceQuery != null)
          widget.bookSourceQuery!(sources: sources, keyword: query).then(
            (batch) {
              if (!cancelled()) merged.booksDone(batch.hits, batch.errors);
            },
          ),
        if (sources.isNotEmpty && widget.bookSourceQuery == null)
          searchLegadoSources(
            sources: sources,
            keyword: query,
            fetch: widget.bookSourceFetch ?? fetchLegado,
            isCancelled: cancelled,
            onProgress: merged.books,
          ),
      ]);
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      _rebuild(() {
        feed.loading = false;
        feed.error = userFacingError(error);
      });
    }
  }

  void _applyBookHits(
    _SearchFeed feed,
    List<MediaItem> items,
    List<String> errors, {
    required bool done,
    int finished = 0,
    int total = 0,
  }) {
    if (!mounted) return;
    final failed = errors.isEmpty ? '' : '，${errors.length} 个书源失败';
    _rebuild(() {
      feed.items
        ..clear()
        ..addAll(items);
      feed.seen
        ..clear()
        ..addAll(items.map((item) => '${item.kind}:${item.id}'));
      feed.hasMore = false;
      feed.initialized = true;
      feed.loading = !done;
      feed.error = done && items.isEmpty && errors.isNotEmpty
          ? errors.join('\n')
          : null;
      _bookSourceStatus = done
          ? '按已添加的书源搜索$failed'
          : '正在搜索 $finished/$total$failed';
    });
  }

  String _emptyResultText(_SearchFeed feed) {
    if (_idQuery != null) {
      return _feeds.first.items.isEmpty ? '未找到该 ID 对应的作品' : '该分类下没有匹配的作品';
    }
    if (_bookSourceMode && feed.loading) return _bookSourceStatus;
    if (_bookSourceMode &&
        _bookSources.loaded &&
        _bookSources.scopeId == 'ok' &&
        _bookSources.selected.isEmpty) {
      return '还没有校验通过的书源，请先在「我的 → 书源」校验';
    }
    if (_bookSourceMode &&
        _bookSources.loaded &&
        !_bookSources.hasEnabledSource) {
      return bookSourceEmptyMessage;
    }
    if (_fanqieSource && _minimumScore > 0) return '已加载结果中暂无达到评分的作品';
    return feed.hasMore ? '当前页暂无匹配结果' : '无结果';
  }

  String _resultMeta(MediaItem item) {
    if (isCustomSourceMark(item.source)) {
      return [
        if (item.author.isNotEmpty) item.author,
        if (item.badge.isNotEmpty) item.badge,
        if (item.ep.isNotEmpty) item.ep,
      ].join(' · ');
    }
    return [
      if (item.author.isNotEmpty) item.author,
      kindLabels[item.kind] ?? item.kind,
      if (mediaLengthLabel(item).isNotEmpty) mediaLengthLabel(item),
      if (item.score != null)
        '${item.score!.toStringAsFixed(1)}分'
      else if (!isShuqiItem(item))
        '暂无评分',
    ].join(' · ');
  }
}

typedef _MergedReport =
    void Function(
      List<MediaItem> items,
      List<String> errors,
      bool done,
      int finished,
      int total,
    );

/// 书源和漫画源扩展各自汇报进度，这里合成一份结果：书源结果在前。
class _MergedSourceSearch {
  _MergedSourceSearch(
    this._report, {
    required bool hasBooks,
    required bool hasComics,
  }) : _booksDone = !hasBooks,
       _comicsDone = !hasComics;

  final _MergedReport _report;
  List<MediaItem> _books = const [];
  List<String> _bookErrors = const [];
  int _bookFinished = 0;
  int _bookTotal = 0;
  bool _booksDone;
  ExtensionSearchProgress? _comics;
  bool _comicsDone;

  void books(LegadoSearchProgress progress) {
    _books = [for (final hit in progress.hits) hit.toMediaItem()];
    _bookErrors = progress.errors;
    _bookFinished = progress.finished;
    _bookTotal = progress.total;
    _booksDone = progress.done;
    _emit();
  }

  void booksDone(List<LegadoHit> hits, List<String> errors) {
    _books = [for (final hit in hits) hit.toMediaItem()];
    _bookErrors = errors;
    _booksDone = true;
    _emit();
  }

  void comics(ExtensionSearchProgress progress) {
    _comics = progress;
    _emit();
  }

  void comicsDone(ExtensionSearchProgress progress) {
    _comics = progress;
    _comicsDone = true;
    _emit();
  }

  void _emit() {
    final comics = _comics;
    _report(
      [..._books, ...?comics?.items],
      [..._bookErrors, ...?comics?.errors],
      _booksDone && _comicsDone,
      _bookFinished + (comics?.finished ?? 0),
      _bookTotal + (comics?.total ?? 0),
    );
  }
}
