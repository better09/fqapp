import 'package:flutter/material.dart';

import '../legado/book_source.dart';
import '../legado/open_book.dart';
import '../legado/web_book.dart';

/// 用已启用的文字书源搜索，点结果后按规则打开目录和正文。
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
  late final Future<LegadoSearchBatch> _search = searchLegadoSources(
    sources: widget.sources,
    keyword: widget.keyword,
    fetch: widget.fetch,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('搜索「${widget.keyword}」')),
      body: FutureBuilder<LegadoSearchBatch>(
        future: _search,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final batch = snapshot.data;
          if (batch == null) {
            return Center(child: Text('${snapshot.error}'));
          }
          if (batch.hits.isEmpty && batch.errors.isEmpty) {
            return const Center(child: Text('没有找到相关书籍'));
          }
          return ListView(
            children: [
              for (final hit in batch.hits)
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
              for (final error in batch.errors)
                ListTile(
                  title: Text(error, style: const TextStyle(fontSize: 13)),
                ),
            ],
          );
        },
      ),
    );
  }
}
