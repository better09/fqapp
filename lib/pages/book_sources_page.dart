import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../legado/book_source.dart';
import '../legado/book_source_store.dart';
import 'source_search_page.dart';

/// 自定义书源：导入阅读（Legado）的 JSON，再用这些规则搜索和阅读网络内容。
class BookSourcesPage extends StatefulWidget {
  final BookSourceRepository? repository;

  const BookSourcesPage({super.key, this.repository});

  @override
  State<BookSourcesPage> createState() => _BookSourcesPageState();
}

class _BookSourcesPageState extends State<BookSourcesPage> {
  late final BookSourceRepository _repository =
      widget.repository ?? HiveBookSourceRepository();
  List<LegadoBookSource> _sources = const [];
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final sources = await _repository.load();
    if (!mounted) return;
    setState(() => _sources = sources);
  }

  Future<void> _save(List<LegadoBookSource> sources) async {
    await _repository.save(sources);
    if (!mounted) return;
    setState(() => _sources = sources);
  }

  Future<void> _import() async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => const _ImportDialog(),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    try {
      final incoming = parseBookSources(await _loadImportText(text.trim()));
      final merged = [..._sources];
      for (final source in incoming) {
        final index = merged.indexWhere((item) => item.url == source.url);
        if (index >= 0) {
          merged[index] = source;
        } else {
          merged.add(source);
        }
      }
      await _save(merged);
      if (!mounted) return;
      _tell('已导入 ${incoming.length} 个书源');
    } catch (error) {
      if (!mounted) return;
      _tell('$error');
    }
  }

  Future<void> _search() async {
    final keyword = _query.text.trim();
    if (keyword.isEmpty) {
      _tell('先输入要搜的书名');
      return;
    }
    final enabled = _sources.where(
      (source) => source.enabled && source.type == 0,
    );
    if (enabled.isEmpty) {
      _tell('没有启用的文字书源');
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            SourceSearchPage(keyword: keyword, sources: enabled.toList()),
      ),
    );
  }

  void _tell(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源'),
        actions: [
          IconButton(
            key: const Key('book-source-import'),
            tooltip: '导入书源',
            onPressed: _import,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _list()),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('book-source-query'),
                      controller: _query,
                      decoration: const InputDecoration(hintText: '用已启用的书源搜索'),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('book-source-search'),
                    onPressed: _search,
                    child: const Text('搜索'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    if (_sources.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '还没有书源。点右上角导入阅读（Legado）的书源 JSON 或订阅地址，就可以按规则搜索和阅读网络内容。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _sources.length,
      itemBuilder: (context, index) {
        final source = _sources[index];
        final subtitle = [
          if (source.group.isNotEmpty) source.group,
          if (source.type != 0) '非文字书源，搜索时会跳过',
        ].join(' · ');
        return SwitchListTile(
          title: Text(source.name),
          subtitle: subtitle.isEmpty ? null : Text(subtitle),
          value: source.enabled,
          secondary: IconButton(
            tooltip: '删除',
            onPressed: () {
              final next = [..._sources]..removeAt(index);
              unawaited(_save(next));
            },
            icon: const Icon(Icons.delete_outline),
          ),
          onChanged: (enabled) {
            final next = [..._sources];
            next[index] = source.withEnabled(enabled);
            unawaited(_save(next));
          },
        );
      },
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入书源'),
      content: TextField(
        key: const Key('book-source-import-field'),
        controller: _controller,
        minLines: 3,
        maxLines: 8,
        decoration: const InputDecoration(hintText: '粘贴阅读书源 JSON，或填订阅地址'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          key: const Key('book-source-import-confirm'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('导入'),
        ),
      ],
    );
  }
}

Future<String> _loadImportText(String text) async {
  if (!text.startsWith('http://') && !text.startsWith('https://')) return text;
  final response = await http
      .get(Uri.parse(text))
      .timeout(const Duration(seconds: 20));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw FormatException('订阅地址请求失败（${response.statusCode}）');
  }
  return response.body;
}
