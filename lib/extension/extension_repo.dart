import 'dart:convert';

import 'package:http/http.dart' as http;

import '../legado/analyze_url.dart' show legadoDefaultUserAgent;
import 'extension_store.dart';

const _repoTimeout = Duration(seconds: 20);

/// 扩展仓库 index.json 里的一项（Venera 格式）。
class ExtensionRepoEntry {
  const ExtensionRepoEntry({
    required this.name,
    required this.scriptUrl,
    this.version = '',
    this.description = '',
  });

  final String name;
  final String scriptUrl;
  final String version;
  final String description;

  /// 文件名（不含扩展名），和已安装扩展的 key 大多一致，用来对上安装状态。
  String get fileKey {
    final path = Uri.tryParse(scriptUrl)?.pathSegments.lastOrNull ?? '';
    return path.endsWith('.js') ? path.substring(0, path.length - 3) : path;
  }

  InstalledComicExtension? installedIn(List<InstalledComicExtension> items) {
    for (final item in items) {
      if (item.updateUrl == scriptUrl || item.key == fileKey) return item;
    }
    return null;
  }
}

typedef ExtensionFetcher = Future<String> Function(Uri url);

Future<String> fetchExtensionText(Uri url) async {
  final response = await http
      .get(url, headers: {'User-Agent': legadoDefaultUserAgent})
      .timeout(_repoTimeout);
  if (response.statusCode >= 400) {
    throw Exception('下载失败（HTTP ${response.statusCode}）');
  }
  return utf8.decode(response.bodyBytes, allowMalformed: true);
}

/// 解析仓库索引：每项给 `url`（绝对地址）或 `filename`（相对索引地址）。
List<ExtensionRepoEntry> parseExtensionRepo(String body, Uri indexUrl) {
  final decoded = jsonDecode(body);
  if (decoded is! List) throw const FormatException('仓库索引应是 JSON 数组');
  final entries = <ExtensionRepoEntry>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final url = '${item['url'] ?? ''}'.trim();
    final filename = '${item['filename'] ?? item['fileName'] ?? ''}'.trim();
    final target = url.isNotEmpty
        ? url
        : filename.isNotEmpty
        ? indexUrl.resolve(filename).toString()
        : '';
    if (target.isEmpty) continue;
    entries.add(
      ExtensionRepoEntry(
        name: '${item['name'] ?? target}',
        scriptUrl: target,
        version: '${item['version'] ?? ''}',
        description: '${item['description'] ?? ''}',
      ),
    );
  }
  return entries;
}

Future<List<ExtensionRepoEntry>> loadExtensionRepo(
  String indexUrl, {
  ExtensionFetcher fetch = fetchExtensionText,
}) async {
  final uri = Uri.parse(indexUrl.trim());
  return parseExtensionRepo(await fetch(uri), uri);
}
