part of 'search_page.dart';

extension _BookSourceSearch on _SearchPageState {
  Future<void> _loadBookSourceCatalog(int generation) async {
    if (_bookSources.loaded) return;
    try {
      final catalog =
          await (widget.bookSourceCatalog ?? loadStoredBookSources)();
      if (!mounted || generation != _requestGeneration) return;
      _rebuild(() {
        _bookSources.catalog = catalog;
        _bookSources.loaded = true;
      });
    } catch (_) {
      // 范围条先留「全部」，真正搜索时再报错。
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

  /// 按当前范围同时查已启用的文字书源，每返回一个书源就刷新一次结果。
  Future<void> _searchBookSources(String query, int generation) async {
    final feed = _feeds[0];
    _rebuild(() {
      feed.loading = true;
      feed.error = null;
    });
    try {
      if (!_bookSources.loaded) {
        await _loadBookSourceCatalog(generation);
        if (!mounted || generation != _requestGeneration) return;
      }
      final sources = _bookSources.selected;
      if (sources.isEmpty) {
        _rebuild(() {
          feed.items.clear();
          feed.initialized = true;
          feed.loading = false;
          feed.hasMore = false;
        });
        return;
      }
      if (widget.bookSourceQuery != null) {
        final batch = await widget.bookSourceQuery!(
          sources: sources,
          keyword: query,
        );
        if (!mounted || generation != _requestGeneration) return;
        _applyBookHits(feed, batch.hits, batch.errors, done: true);
        return;
      }
      await searchLegadoSources(
        sources: sources,
        keyword: query,
        isCancelled: () => !mounted || generation != _requestGeneration,
        onProgress: (progress) => _applyBookHits(
          feed,
          progress.hits,
          progress.errors,
          done: progress.done,
          finished: progress.finished,
          total: progress.total,
        ),
      );
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
    List<LegadoHit> hits,
    List<String> errors, {
    required bool done,
    int finished = 0,
    int total = 0,
  }) {
    if (!mounted) return;
    final items = [for (final hit in hits) hit.toMediaItem()];
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
        !_bookSources.hasEnabledSource) {
      return bookSourceEmptyMessage;
    }
    if (_fanqieSource && _minimumScore > 0) return '已加载结果中暂无达到评分的作品';
    return feed.hasMore ? '当前页暂无匹配结果' : '无结果';
  }

  String _resultMeta(MediaItem item) {
    if (item.source == legadoSourceMark) {
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
