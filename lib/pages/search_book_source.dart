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

/// 书城搜索里「书源」来源的范围。空范围表示全部已启用的文字书源。
class BookSourceSearchSession {
  List<LegadoBookSource> catalog = const [];
  bool loaded = false;
  String scopeId = '';

  List<BookSourceScopeChoice> get choices => bookSourceScopeChoices(catalog);

  int get selectedIndex {
    final index = choices.indexWhere((choice) => choice.id == scopeId);
    return index < 0 ? 0 : index;
  }

  List<LegadoBookSource> get selected => sourcesInScope(catalog, scopeId);

  bool get hasEnabledSource =>
      catalog.any((source) => source.enabled && source.type == 0);
}

const bookSourceEmptyMessage = '还没有启用的书源，请先在「我的 → 书源」导入';

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

List<LegadoBookSource> enabledTextSources(List<LegadoBookSource> sources) =>
    sources.where((source) => source.enabled && source.type == 0).toList();

/// 范围条：全部、校验可用，以及每个分组。单条书源不放进菜单，避免上百个选项把点击卡住。
List<BookSourceScopeChoice> bookSourceScopeChoices(
  List<LegadoBookSource> sources,
) {
  final enabled = enabledTextSources(sources);
  final groups = <String>[];
  for (final source in enabled) {
    for (final name in bookSourceGroupNames(source)) {
      if (!groups.contains(name)) groups.add(name);
    }
  }
  return [
    const BookSourceScopeChoice('', '全部'),
    const BookSourceScopeChoice('ok', '校验可用'),
    for (final group in groups) BookSourceScopeChoice('g:$group', group),
  ];
}

List<LegadoBookSource> sourcesInScope(
  List<LegadoBookSource> sources,
  String scopeId,
) {
  final enabled = enabledTextSources(sources);
  if (scopeId == 'ok') {
    return enabled.where((source) => source.checkedOk).toList();
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
