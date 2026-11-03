import 'dart:async';

import 'package:flutter/material.dart';

import '../legado/book_source.dart';
import '../legado/open_book.dart';
import '../legado/web_book.dart';

/// 用已启用的文字书源搜索，点结果后按规则打开目录和正文。
///
/// 结果随每个书源返回立刻出现，顶上显示已完成数量，避免慢书源把整页卡住。
class SourceSearchPage extends StatefulWidget {
  final String keyword;
  final List<LegadoBookSource> sources;
  final LegadoFetcher fetch;

  const SourceSearchPage({
    super.key,
    required this.keyword,
    required this.sources,
    this.fetch = fetchLegado,
  });

  @override
  State<SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<SourceSearchPage> {
  final _hits = <LegadoHit>[];
  final _errors = <String>[];
  int _finished = 0;
  int _total = 0;
  var _alive = true;
  var _reported = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _alive = false;
    super.dispose();
  }

  Future<void> _run() async {
    try {
      await searchLegadoSources(
        sources: widget.sources,
        keyword: widget.keyword,
        fetch: widget.fetch,
        isCancelled: () => !_alive,
        onProgress: _show,
      );
    } catch (error) {
      if (!_alive || !mounted) return;
      setState(() => _failure = '$error');
    }
  }

  void _show(LegadoSearchProgress progress) {
    if (!_alive || !mounted) return;
    setState(() {
      _reported = true;
      _hits
        ..clear()
        ..addAll(progress.hits);
      _errors
        ..clear()
        ..addAll(progress.errors);
      _finished = progress.finished;
      _total = progress.total;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('搜索「${widget.keyword}」')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _status(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  bool get _searching => _failure == null && (!_reported || _finished < _total);

  String get _statusText {
    if (_failure != null) return _failure!;
    if (!_reported) return '正在搜索…';
    if (_total == 0) return '没有启用的文字书源';
    if (_finished < _total) return '正在搜索 $_finished/$_total';
    return '搜索完成 $_finished/$_total';
  }

  Widget _status() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          if (_searching) ...[
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(_statusText)),
        ],
      ),
    );
  }

  Widget _body() {
    if (_hits.isEmpty && _errors.isEmpty) {
      if (_finished >= _total && _total > 0) {
        return const Center(child: Text('没有找到相关书籍'));
      }
      return const SizedBox.shrink();
    }
    return ListView(
      children: [
        for (final hit in _hits)
          ListTile(
            title: Text(hit.name),
            subtitle: Text(
              [
                if (hit.author.isNotEmpty) hit.author,
                hit.source.name,
              ].join(' · '),
            ),
            onTap: () => openLegadoHit(context, hit),
          ),
        for (final error in _errors)
          ListTile(title: Text(error, style: const TextStyle(fontSize: 13))),
      ],
    );
  }
}
