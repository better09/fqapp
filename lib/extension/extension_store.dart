import 'dart:convert';

import 'package:hive_ce/hive.dart';

import '../services/encrypted_hive.dart';

/// 一个已安装的漫画源扩展（Venera 格式的 JS 脚本）。
class InstalledComicExtension {
  const InstalledComicExtension({
    required this.key,
    required this.name,
    required this.version,
    required this.script,
    this.updateUrl = '',
    this.enabled = true,
  });

  final String key;
  final String name;
  final String version;
  final String script;

  /// 脚本里的 `url` 字段，或从仓库安装时的下载地址，用于检查更新。
  final String updateUrl;
  final bool enabled;

  InstalledComicExtension copyWith({bool? enabled}) => InstalledComicExtension(
    key: key,
    name: name,
    version: version,
    script: script,
    updateUrl: updateUrl,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'version': version,
    'script': script,
    'updateUrl': updateUrl,
    'enabled': enabled,
  };

  static InstalledComicExtension? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = '${raw['key'] ?? ''}';
    final script = '${raw['script'] ?? ''}';
    if (key.isEmpty || script.isEmpty) return null;
    return InstalledComicExtension(
      key: key,
      name: '${raw['name'] ?? key}',
      version: '${raw['version'] ?? ''}',
      script: script,
      updateUrl: '${raw['updateUrl'] ?? ''}',
      enabled: raw['enabled'] != false,
    );
  }
}

/// 扩展相关的本地数据。页面和引擎测试可以换成内存实现。
abstract class ComicExtensionStore {
  Future<List<InstalledComicExtension>> loadExtensions();
  Future<void> saveExtensions(List<InstalledComicExtension> items);

  /// 脚本通过 `saveData` 写入的数据（账号、令牌、设置等），按扩展 key 分开。
  Future<Map<String, dynamic>> loadData(String key);
  Future<void> saveData(String key, Map<String, dynamic> data);
  Future<void> deleteData(String key);

  Future<List<String>> loadRepos();
  Future<void> saveRepos(List<String> urls);

  Future<Map<String, Map<String, String>>> loadCookies();
  Future<void> saveCookies(Map<String, Map<String, String>> cookies);
}

class MemoryComicExtensionStore implements ComicExtensionStore {
  List<InstalledComicExtension> extensions = [];
  final data = <String, Map<String, dynamic>>{};
  List<String> repos = [];
  Map<String, Map<String, String>> cookies = {};

  @override
  Future<List<InstalledComicExtension>> loadExtensions() async => extensions;

  @override
  Future<void> saveExtensions(List<InstalledComicExtension> items) async {
    extensions = List.of(items);
  }

  @override
  Future<Map<String, dynamic>> loadData(String key) async =>
      Map.of(data[key] ?? const {});

  @override
  Future<void> saveData(String key, Map<String, dynamic> value) async {
    data[key] = Map.of(value);
  }

  @override
  Future<void> deleteData(String key) async {
    data.remove(key);
  }

  @override
  Future<List<String>> loadRepos() async => repos;

  @override
  Future<void> saveRepos(List<String> urls) async {
    repos = List.of(urls);
  }

  @override
  Future<Map<String, Map<String, String>>> loadCookies() async => cookies;

  @override
  Future<void> saveCookies(Map<String, Map<String, String>> value) async {
    cookies = value;
  }
}

class HiveComicExtensionStore implements ComicExtensionStore {
  static const boxName = 'comic_extensions';
  Box<dynamic>? _box;

  Future<Box<dynamic>> _open() async =>
      _box ??= await EncryptedHive.openBox<dynamic>(Hive, boxName);

  Future<Object?> _json(String key) async {
    final raw = (await _open()).get(key);
    if (raw is! String || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _put(String key, Object? value) async =>
      (await _open()).put(key, jsonEncode(value));

  @override
  Future<List<InstalledComicExtension>> loadExtensions() async {
    final raw = await _json('extensions');
    if (raw is! List) return const [];
    return [
      for (final item in raw) ?InstalledComicExtension.fromJson(item),
    ];
  }

  @override
  Future<void> saveExtensions(List<InstalledComicExtension> items) =>
      _put('extensions', items.map((item) => item.toJson()).toList());

  @override
  Future<Map<String, dynamic>> loadData(String key) async {
    final raw = await _json('data:$key');
    return raw is Map ? Map<String, dynamic>.from(raw) : {};
  }

  @override
  Future<void> saveData(String key, Map<String, dynamic> data) =>
      _put('data:$key', data);

  @override
  Future<void> deleteData(String key) async =>
      (await _open()).delete('data:$key');

  @override
  Future<List<String>> loadRepos() async {
    final raw = await _json('repos');
    return raw is List ? raw.map((item) => '$item').toList() : const [];
  }

  @override
  Future<void> saveRepos(List<String> urls) => _put('repos', urls);

  @override
  Future<Map<String, Map<String, String>>> loadCookies() async {
    final raw = await _json('cookies');
    if (raw is! Map) return {};
    return {
      for (final entry in raw.entries)
        if (entry.value is Map)
          '${entry.key}': {
            for (final cookie in (entry.value as Map).entries)
              '${cookie.key}': '${cookie.value}',
          },
    };
  }

  @override
  Future<void> saveCookies(Map<String, Map<String, String>> cookies) =>
      _put('cookies', cookies);
}
