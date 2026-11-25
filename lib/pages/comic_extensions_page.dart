import 'dart:async';

import 'package:flutter/material.dart';

import '../extension/comic_extension.dart';
import '../extension/extension_repo.dart';
import '../extension/extension_store.dart';

/// 漫画源扩展管理：添加扩展仓库（Venera 的 index.json），从仓库安装/更新，
/// 或直接导入单个 .js 漫画源。应用不内置任何仓库或漫画源。
class ComicExtensionsPage extends StatefulWidget {
  const ComicExtensionsPage({
    super.key,
    this.client,
    this.store,
    this.fetch = fetchExtensionText,
  });

  final ComicExtensionClient? client;
  final ComicExtensionStore? store;
  final ExtensionFetcher fetch;

  @override
  State<ComicExtensionsPage> createState() => _ComicExtensionsPageState();
}

class _ComicExtensionsPageState extends State<ComicExtensionsPage> {
  late final ComicExtensionClient _client =
      widget.client ?? ComicExtensionRuntime.shared;
  late final ComicExtensionStore _store =
      widget.store ?? HiveComicExtensionStore();
  List<InstalledComicExtension> _installed = const [];
  List<String> _repos = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final installed = await _client.installed();
    final repos = await _store.loadRepos();
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _repos = repos;
      _loading = false;
    });
  }

  Future<void> _run(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final message = await action();
      if (message != null) _tell(message);
    } catch (error) {
      _tell('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  void _tell(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _ask(String title, String hint) => showDialog<String>(
    context: context,
    builder: (_) => _InputDialog(title: title, hint: hint),
  );

  Future<void> _addRepo() async {
    final url = await _ask('添加扩展仓库', '仓库 index.json 地址');
    if (url == null || url.isEmpty) return;
    await _run(() async {
      final entries = await loadExtensionRepo(url, fetch: widget.fetch);
      if (!_repos.contains(url)) await _store.saveRepos([..._repos, url]);
      return '已添加仓库，共 ${entries.length} 个漫画源';
    });
  }

  Future<void> _removeRepo(String url) => _run(() async {
    await _store.saveRepos([..._repos]..remove(url));
    return null;
  });

  Future<void> _importScript() async {
    final input = await _ask('导入漫画源', '.js 地址，或直接粘贴脚本内容');
    if (input == null || input.isEmpty) return;
    await _run(() async {
      final isUrl = input.startsWith('http://') || input.startsWith('https://');
      final script = isUrl ? await widget.fetch(Uri.parse(input)) : input;
      final installed = await _client.install(
        script,
        updateUrl: isUrl ? input : '',
      );
      return '已安装 ${installed.name}';
    });
  }

  Future<void> _installEntry(ExtensionRepoEntry entry) => _run(() async {
    final script = await widget.fetch(Uri.parse(entry.scriptUrl));
    final installed = await _client.install(
      script,
      updateUrl: entry.scriptUrl,
    );
    return '已安装 ${installed.name} ${installed.version}';
  });

  Future<void> _updateInstalled(InstalledComicExtension item) => _run(() async {
    final script = await widget.fetch(Uri.parse(item.updateUrl));
    final installed = await _client.install(script, updateUrl: item.updateUrl);
    return installed.version == item.version
        ? '${item.name} 已是最新'
        : '${item.name} 已更新到 ${installed.version}';
  });

  Future<void> _remove(InstalledComicExtension item) => _run(() async {
    await _client.remove(item.key);
    return '已删除 ${item.name}';
  });

  void _openRepo(String url) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _RepoEntriesPage(
          url: url,
          fetch: widget.fetch,
          installed: () => _installed,
          onInstall: _installEntry,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('漫画源'),
        actions: [
          IconButton(
            key: const Key('extension-add-repo'),
            tooltip: '添加扩展仓库',
            onPressed: _busy ? null : _addRepo,
            icon: const Icon(Icons.add_link),
          ),
          IconButton(
            key: const Key('extension-import'),
            tooltip: '导入漫画源',
            onPressed: _busy ? null : _importScript,
            icon: const Icon(Icons.file_download_outlined),
          ),
        ],
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: _sections(context)),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final hint = Theme.of(context).textTheme.bodySmall;
    return [
      if (_repos.isEmpty && _installed.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '支持 Venera 格式的漫画源：点右上角添加扩展仓库（index.json 地址），'
            '或导入单个 .js 漫画源。本应用不内置任何仓库和漫画源，请自行添加合法来源。',
            textAlign: TextAlign.center,
            style: hint,
          ),
        ),
      if (_repos.isNotEmpty) const ListTile(dense: true, title: Text('扩展仓库')),
      for (final url in _repos)
        ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => _openRepo(url),
          trailing: IconButton(
            tooltip: '移除仓库',
            onPressed: _busy ? null : () => _removeRepo(url),
            icon: const Icon(Icons.delete_outline),
          ),
        ),
      if (_installed.isNotEmpty)
        const ListTile(dense: true, title: Text('已安装')),
      for (final item in _installed) _installedTile(item),
    ];
  }

  Widget _installedTile(InstalledComicExtension item) {
    return SwitchListTile(
      key: Key('extension-${item.key}'),
      title: Text(item.name),
      subtitle: Text(
        [if (item.version.isNotEmpty) 'v${item.version}', item.key].join(' · '),
      ),
      value: item.enabled,
      onChanged: _busy
          ? null
          : (value) => _run(() async {
              await _client.setEnabled(item.key, value);
              return null;
            }),
      secondary: PopupMenuButton<String>(
        tooltip: '更多',
        onSelected: (action) {
          if (action == 'update') unawaited(_updateInstalled(item));
          if (action == 'remove') unawaited(_remove(item));
        },
        itemBuilder: (_) => [
          if (item.updateUrl.isNotEmpty)
            const PopupMenuItem(value: 'update', child: Text('检查更新')),
          const PopupMenuItem(value: 'remove', child: Text('删除')),
        ],
      ),
    );
  }
}

class _InputDialog extends StatefulWidget {
  const _InputDialog({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('extension-input'),
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 6,
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('extension-input-ok'),
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _RepoEntriesPage extends StatefulWidget {
  const _RepoEntriesPage({
    required this.url,
    required this.fetch,
    required this.installed,
    required this.onInstall,
  });

  final String url;
  final ExtensionFetcher fetch;
  final List<InstalledComicExtension> Function() installed;
  final Future<void> Function(ExtensionRepoEntry entry) onInstall;

  @override
  State<_RepoEntriesPage> createState() => _RepoEntriesPageState();
}

class _RepoEntriesPageState extends State<_RepoEntriesPage> {
  late Future<List<ExtensionRepoEntry>> _entries = _load();
  String? _installing;

  Future<List<ExtensionRepoEntry>> _load() =>
      loadExtensionRepo(widget.url, fetch: widget.fetch);

  Future<void> _install(ExtensionRepoEntry entry) async {
    setState(() => _installing = entry.scriptUrl);
    await widget.onInstall(entry);
    if (mounted) setState(() => _installing = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('仓库漫画源')),
      body: FutureBuilder<List<ExtensionRepoEntry>>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(() => _entries = _load()),
                child: Text('仓库读取失败，点此重试\n${snapshot.error}'),
              ),
            );
          }
          final entries = snapshot.data;
          if (entries == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (entries.isEmpty) return const Center(child: Text('仓库里没有漫画源'));
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) => _tile(entries[index]),
          );
        },
      ),
    );
  }

  Widget _tile(ExtensionRepoEntry entry) {
    final installed = entry.installedIn(widget.installed());
    final upgradable =
        installed != null &&
        entry.version.isNotEmpty &&
        compareVersions(entry.version, installed.version) > 0;
    final label = installed == null
        ? '安装'
        : upgradable
        ? '更新'
        : '已安装';
    final enabled = (installed == null || upgradable) && _installing == null;
    return ListTile(
      title: Text(entry.name),
      subtitle: Text(
        [
          if (entry.version.isNotEmpty) 'v${entry.version}',
          if (entry.description.isNotEmpty) entry.description,
        ].join(' · '),
      ),
      trailing: _installing == entry.scriptUrl
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              key: Key('repo-install-${entry.fileKey}'),
              onPressed: enabled ? () => _install(entry) : null,
              child: Text(label),
            ),
    );
  }
}
