import 'dart:convert';

/// 阅读搜索/目录链接解析后的一次请求。
class LegadoRequest {
  final Uri url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final String? charset;

  const LegadoRequest({
    required this.url,
    required this.method,
    required this.headers,
    this.body,
    this.charset,
  });
}

const legadoDefaultUserAgent =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 展开 `{{key}}`、`{{page}}`、`<第1页,第2页>`，并拆出 `,{...}` 里的请求选项。
LegadoRequest analyzeLegadoUrl(
  String ruleUrl, {
  required String base,
  String key = '',
  int page = 1,
  Map<String, String> headers = const {},
}) {
  final split = _splitOptions(ruleUrl.trim());
  final url = _resolve(base, _fillUrl(split.url, key: key, page: page));
  final option = split.option;
  final method = (option?['method'] ?? 'GET').toString().toUpperCase();
  final merged = <String, String>{
    'User-Agent': legadoDefaultUserAgent,
    ...headers,
    ..._stringMap(option?['headers']),
  };
  final body = _fillBody(option?['body'], key: key, page: page);
  final charset = _optionalText(option?['charset']);
  if (body != null &&
      !merged.keys.any((name) => name.toLowerCase() == 'content-type')) {
    merged['Content-Type'] = 'application/x-www-form-urlencoded';
  }
  return LegadoRequest(
    url: url,
    method: method,
    headers: merged,
    body: body,
    charset: charset,
  );
}

String? _optionalText(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

({String url, Map<String, dynamic>? option}) _splitOptions(String rule) {
  final comma = rule.indexOf(',{');
  if (comma < 0) return (url: rule, option: null);
  try {
    final decoded = jsonDecode(rule.substring(comma + 1));
    if (decoded is Map<String, dynamic>) {
      return (url: rule.substring(0, comma), option: decoded);
    }
    if (decoded is Map) {
      return (
        url: rule.substring(0, comma),
        option: Map<String, dynamic>.from(decoded),
      );
    }
  } catch (_) {
    // 逗号后面不是请求选项，整段都当链接。
  }
  return (url: rule, option: null);
}

String _fillUrl(String url, {required String key, required int page}) {
  final encoded = Uri.encodeQueryComponent(key);
  return _fillPage(
    url,
    page,
  ).replaceAll('{{key}}', encoded).replaceAll('{{page}}', '$page');
}

String _fillPage(String url, int page) {
  return url.replaceAllMapped(RegExp(r'<([^<>]+)>'), (match) {
    final pages = match.group(1)!.split(',');
    final index = page - 1;
    final picked = index >= 0 && index < pages.length
        ? pages[index]
        : pages.last;
    return picked.trim();
  });
}

String? _fillBody(Object? body, {required String key, required int page}) {
  if (body == null) return null;
  final text = body is String ? body : jsonEncode(body);
  return text.replaceAll('{{key}}', key).replaceAll('{{page}}', '$page');
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, item) => MapEntry('$key', '$item'));
}

Uri resolveLegadoUrl(String base, String target) => _resolve(base, target);

Uri _resolve(String base, String target) {
  final trimmed = target.trim();
  if (trimmed.startsWith('//')) return Uri.parse('https:$trimmed');
  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme) return parsed;
  final baseUri = Uri.tryParse(base);
  if (baseUri == null) return Uri.parse(trimmed);
  return baseUri.resolve(trimmed);
}
