import 'dart:convert';

/// 阅读（Legado）书源里标记「这是自定义网络来源」的 [MediaItem.source]。
const String legadoSourceMark = 'legado';

/// 一条阅读书源。未知字段留在 [raw] 里，导出时原样带回。
class LegadoBookSource {
  final Map<String, dynamic> raw;

  LegadoBookSource(Map<String, dynamic> raw)
    : raw = Map<String, dynamic>.from(raw);

  String get url => _text(raw['bookSourceUrl']);
  String get name =>
      _text(raw['bookSourceName']).isEmpty ? url : _text(raw['bookSourceName']);
  String get group => _text(raw['bookSourceGroup']);
  int get type =>
      raw['bookSourceType'] is int ? raw['bookSourceType'] as int : 0;
  bool get enabled => raw['enabled'] != false;
  String? get searchUrl => _optional(raw['searchUrl']);
  String? get header => _optional(raw['header']);

  LegadoSearchRule get search => LegadoSearchRule(raw['ruleSearch']);
  LegadoBookInfoRule get bookInfo => LegadoBookInfoRule(raw['ruleBookInfo']);
  LegadoTocRule get toc => LegadoTocRule(raw['ruleToc']);
  LegadoContentRule get content => LegadoContentRule(raw['ruleContent']);

  Map<String, String> get headers => decodeLegadoHeaders(header);

  /// 校验结果：`ok` 可用，`fail` 站点无响应，`js` 规则跑不了，`skip` 不是文字书源。
  String? get checkStatus {
    final value = raw['fqCheck']?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  bool get checkedOk => checkStatus == 'ok';

  LegadoBookSource withEnabled(bool value) {
    final next = Map<String, dynamic>.from(raw);
    next['enabled'] = value;
    return LegadoBookSource(next);
  }

  LegadoBookSource withCheck(String status, {bool? enabled}) {
    final next = Map<String, dynamic>.from(raw);
    next['fqCheck'] = status;
    if (enabled != null) next['enabled'] = enabled;
    return LegadoBookSource(next);
  }
}

class LegadoSearchRule {
  final Map<String, dynamic> raw;
  LegadoSearchRule(Object? value) : raw = _ruleMap(value);

  String? get bookList => _optional(raw['bookList']);
  String? get name => _optional(raw['name']);
  String? get author => _optional(raw['author']);
  String? get intro => _optional(raw['intro']);
  String? get kind => _optional(raw['kind']);
  String? get lastChapter => _optional(raw['lastChapter']);
  String? get bookUrl => _optional(raw['bookUrl']);
  String? get coverUrl => _optional(raw['coverUrl']);
}

class LegadoBookInfoRule {
  final Map<String, dynamic> raw;
  LegadoBookInfoRule(Object? value) : raw = _ruleMap(value);

  String? get name => _optional(raw['name']);
  String? get author => _optional(raw['author']);
  String? get intro => _optional(raw['intro']);
  String? get coverUrl => _optional(raw['coverUrl']);
  String? get tocUrl => _optional(raw['tocUrl']);
}

class LegadoTocRule {
  final Map<String, dynamic> raw;
  LegadoTocRule(Object? value) : raw = _ruleMap(value);

  String? get chapterList => _optional(raw['chapterList']);
  String? get chapterName => _optional(raw['chapterName']);
  String? get chapterUrl => _optional(raw['chapterUrl']);
  String? get isVolume => _optional(raw['isVolume']);
  String? get nextTocUrl => _optional(raw['nextTocUrl']);
}

class LegadoContentRule {
  final Map<String, dynamic> raw;
  LegadoContentRule(Object? value) : raw = _ruleMap(value);

  String? get content => _optional(raw['content']);
  String? get nextContentUrl => _optional(raw['nextContentUrl']);
  String? get replaceRegex => _optional(raw['replaceRegex']);
}

Map<String, String> decodeLegadoHeaders(String? header) {
  if (header == null || header.trim().isEmpty) return const {};
  try {
    final decoded = jsonDecode(header);
    if (decoded is! Map) return const {};
    return decoded.map((key, value) => MapEntry('$key', '$value'));
  } catch (_) {
    return const {};
  }
}

/// 订阅正文：单个书源、书源数组，或包着数组的对象。
List<LegadoBookSource> parseBookSources(String raw) {
  final decoded = jsonDecode(raw.trim());
  final items = _sourceItems(decoded);
  final sources = <LegadoBookSource>[];
  for (final item in items) {
    if (item is! Map) continue;
    final map = Map<String, dynamic>.from(item);
    if (_text(map['bookSourceUrl']).isEmpty) continue;
    sources.add(LegadoBookSource(map));
  }
  if (sources.isEmpty) {
    throw const FormatException('没有解析到书源，请确认是阅读的书源 JSON');
  }
  return sources;
}

List<dynamic> _sourceItems(Object? decoded) {
  if (decoded is List) return decoded;
  if (decoded is Map && decoded['bookSourceUrl'] != null) return [decoded];
  if (decoded is Map) {
    for (final value in decoded.values) {
      if (value is List) return value;
    }
  }
  throw const FormatException('不是阅读书源 JSON');
}

Map<String, dynamic> _ruleMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return const {};
}

String _text(Object? value) => value == null ? '' : '$value'.trim();

String? _optional(Object? value) {
  final text = _text(value);
  return text.isEmpty ? null : text;
}
