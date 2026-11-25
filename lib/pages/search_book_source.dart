import '../extension/extension_store.dart';
import '../legado/book_source.dart';
import '../legado/book_source_store.dart';
import '../legado/web_book.dart';

typedef BookSourceCatalogLoader = Future<List<LegadoBookSource>> Function();

typedef BookSourceQuery =
    Future<LegadoSearchBatch> Function({
      required List<LegadoBookSource> sources,
      required String keyword,
    });

/// 阅读搜索范围里的一项：全部、一个分组，或单条书源。
class BookSourceScopeChoice {
  final String id;
  final String label;

  const BookSourceScopeChoice(this.id, this.label);
}

/// 书城搜索里「书源」来源的范围。空范围表示全部已启用的小说和漫画书源。
class BookSourceSearchSession {
  List<LegadoBookSource> catalog = const [];

  /// 已安装的漫画源扩展（Venera 脚本），只算启用的。
  List<InstalledComicExtension> extensions = const [];
  bool loaded = false;
  String scopeId = '';

  List<BookSourceScopeChoice> get choices =>
      bookSourceScopeChoices(catalog, hasExtensions: extensions.isNotEmpty);

  int get selectedIndex {
    final index = choices.indexWhere((choice) => choice.id == scopeId);
    return index < 0 ? 0 : index;
  }

  List<LegadoBookSource> get selected => sourcesInScope(catalog, scopeId);

  /// 「全部」和「漫画」范围连同漫画源扩展一起搜。
  List<InstalledComicExtension> get selectedExtensions =>
      scopeId == '' || scopeId == 't:comic' ? extensions : const [];

  bool get hasEnabledSource =>
      extensions.isNotEmpty ||
      catalog.any((source) => source.enabled && source.readable);
}

const bookSourceEmptyMessage = '还没有启用的书源，请先在「我的 → 书源」导入书源或漫画源';

Future<List<LegadoBookSource>> loadStoredBookSources() =>
    HiveBookSourceRepository().load();

Future<LegadoSearchBatch> queryStoredBookSources({
  required List<LegadoBookSource> sources,
  required String keyword,
}) => searchLegadoSources(sources: sources, keyword: keyword);

List<String> bookSourceGroupNames(LegadoBookSource source) => source.group
    .split(RegExp(r'[,，]'))
    .map((part) => part.trim())
    .where((part) => part.isNotEmpty)
    .toList();

List<LegadoBookSource> enabledReadableSources(
  List<LegadoBookSource> sources,
) => sources.where((source) => source.enabled && source.readable).toList();

/// 范围条：全部、校验可用，有漫画书源或漫画源扩展时再分小说/漫画，以及每个分组。
/// 单条书源不放进菜单，避免上百个选项把点击卡住。
List<BookSourceScopeChoice> bookSourceScopeChoices(
  List<LegadoBookSource> sources, {
  bool hasExtensions = false,
}) {
  final enabled = enabledReadableSources(sources);
  final groups = <String>[];
  for (final source in enabled) {
    for (final name in bookSourceGroupNames(source)) {
      if (!groups.contains(name)) groups.add(name);
    }
  }
  return [
    const BookSourceScopeChoice('', '全部'),
    const BookSourceScopeChoice('ok', '校验可用'),
    if (hasExtensions || enabled.any((source) => source.isComic)) ...const [
      BookSourceScopeChoice('t:text', '小说'),
      BookSourceScopeChoice('t:comic', '漫画'),
    ],
    for (final group in groups) BookSourceScopeChoice('g:$group', group),
  ];
}

List<LegadoBookSource> sourcesInScope(
  List<LegadoBookSource> sources,
  String scopeId,
) {
  final enabled = enabledReadableSources(sources);
  if (scopeId == 'ok') {
    return enabled.where((source) => source.checkedOk).toList();
  }
  if (scopeId == 't:text' || scopeId == 't:comic') {
    final comic = scopeId == 't:comic';
    return enabled.where((source) => source.isComic == comic).toList();
  }
  if (scopeId.startsWith('g:')) {
    final group = scopeId.substring(2);
    return enabled
        .where((source) => bookSourceGroupNames(source).contains(group))
        .toList();
  }
  if (scopeId.startsWith('s:')) {
    final url = scopeId.substring(2);
    return enabled.where((source) => source.url == url).toList();
  }
  return enabled;
}
