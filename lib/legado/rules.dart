import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart';

/// 规则里出现阅读的 JavaScript，当前引擎不会执行。
bool legadoRuleUsesJs(String? rule) {
  if (rule == null || rule.isEmpty) return false;
  final lower = rule.toLowerCase();
  if (lower.contains('@js:') || lower.contains('<js')) return true;
  return RegExp(r'\{\{(?!(?:key|page)\}\})').hasMatch(rule);
}

/// 把响应正文变成规则可以接着选的文档：JSON 对象/数组，或 HTML 文档。
Object parseLegadoDocument(String body) {
  final trimmed = body.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      // 不是合法 JSON 时按网页解析。
    }
  }
  final document = parse(body);
  return document.documentElement ?? document.body ?? document;
}

/// 书单、目录这类规则的结果：一组 HTML 元素或 JSON 对象。
List<Object> legadoNodes(Object document, String? rule) {
  if (rule == null || rule.trim().isEmpty) return const [];
  for (final part in _splitOr(rule)) {
    final found = <Object>[];
    for (final piece in _splitOp(part, '&&')) {
      found.addAll(_nodesOf(document, _coreRule(piece)));
    }
    if (found.isNotEmpty) return found;
  }
  return const [];
}

/// 从一个文档或书单元素上取出字符串。`||` 取第一组成绩，`&&` 拼接。
List<String> legadoTexts(
  Object document,
  String? rule, {
  required String baseUrl,
}) {
  if (rule == null || rule.trim().isEmpty) return const [];
  final alternatives = _splitOp(rule, '||');
  if (alternatives.length > 1) {
    for (final alternative in alternatives) {
      final texts = legadoTexts(document, alternative, baseUrl: baseUrl);
      if (texts.any((text) => text.trim().isNotEmpty)) return texts;
    }
    return const [];
  }
  final pieces = _splitOp(rule, '&&');
  if (pieces.length > 1) {
    final texts = <String>[];
    for (final piece in pieces) {
      texts.addAll(legadoTexts(document, piece, baseUrl: baseUrl));
    }
    return texts;
  }
  return _textsOf(document, rule, baseUrl: baseUrl);
}

String legadoFirst(Object document, String? rule, {required String baseUrl}) {
  for (final text in legadoTexts(document, rule, baseUrl: baseUrl)) {
    if (text.trim().isNotEmpty) return text.trim();
  }
  return '';
}

List<Object> _nodesOf(Object document, String rule) {
  if (rule.isEmpty) return [document];
  if (_jsonRule(rule, document)) return _jsonNodes(_jsonValues(document, rule));
  final root = _asElement(document);
  if (root == null) return const [];
  return _htmlElements(root, _selectorRule(rule));
}

List<String> _textsOf(Object document, String rule, {required String baseUrl}) {
  final parts = rule.split('##');
  final core = parts.first.trim();
  if (core.isEmpty) {
    final text = document is String ? document : _plain(document);
    return [_applyReplace(text, parts)];
  }
  final values = _jsonRule(core, document)
      ? _jsonValues(document, core)
      : _htmlValues(_asElement(document), core);
  final texts = <String>[];
  for (final value in values) {
    final text = _asText(value, baseUrl: baseUrl, attribute: _attribute(core));
    if (text.isEmpty) continue;
    texts.add(_applyReplace(text, parts));
  }
  return texts;
}

List<Object> _jsonNodes(List<dynamic> values) {
  final nodes = <Object>[];
  for (final value in values) {
    if (value is List) {
      nodes.addAll(_jsonNodes(value));
      continue;
    }
    if (value is Map) nodes.add(Map<String, dynamic>.from(value));
  }
  return nodes;
}

List<dynamic> _jsonValues(Object document, String rule) {
  var path = rule.trim();
  if (path.toLowerCase().startsWith('@json:')) path = path.substring(6);
  if (path.startsWith(r'$')) path = path.substring(1);
  if (path.startsWith('.')) path = path.substring(1);
  return _walkJson(document, path);
}

List<dynamic> _walkJson(Object node, String path) {
  var current = <dynamic>[node];
  for (final token in _jsonTokens(path)) {
    final next = <dynamic>[];
    for (final item in current) {
      next.addAll(_stepJson(item, token));
    }
    current = next;
  }
  return current;
}

List<dynamic> _stepJson(dynamic item, String token) {
  if (token == '[*]') return item is List ? item : const [];
  if (token.startsWith('[')) {
    if (item is! List) return const [];
    final index = int.tryParse(token.substring(1, token.length - 1));
    if (index == null) return const [];
    final resolved = index < 0 ? item.length + index : index;
    if (resolved < 0 || resolved >= item.length) return const [];
    return [item[resolved]];
  }
  if (item is Map && item.containsKey(token)) return [item[token]];
  return const [];
}

List<String> _jsonTokens(String path) {
  if (path.isEmpty) return const [];
  return RegExp(
    r'\[\*\]|\[-?\d+\]|[^.\[\]]+',
  ).allMatches(path).map((match) => match.group(0)!).toList();
}

List<Element> _htmlElements(Element root, String rule) {
  var current = <Element>[root];
  for (final segment in _segments(rule)) {
    final next = <Element>[];
    for (final element in current) {
      next.addAll(_oneSegment(element, segment));
    }
    current = next;
  }
  return current;
}

List<dynamic> _htmlValues(Element? root, String rule) {
  if (root == null) return const [];
  final attribute = _attribute(rule);
  final elements = _htmlElements(root, _selectorRule(rule));
  if (attribute == null) return elements;
  return elements.map((element) => _readAttribute(element, attribute)).toList();
}

List<Element> _oneSegment(Element element, String segment) {
  final indexed = _indexed(segment);
  final selected = _select(element, indexed.selector);
  if (indexed.index == null) return selected;
  final index = indexed.index!;
  final resolved = index < 0 ? selected.length + index : index;
  if (resolved < 0 || resolved >= selected.length) return const [];
  return [selected[resolved]];
}

List<Element> _select(Element element, String selector) {
  if (selector.isEmpty || selector == 'children') {
    return element.children;
  }
  if (selector.startsWith('class.')) {
    return element.getElementsByClassName(selector.substring(6));
  }
  if (selector.startsWith('tag.')) {
    return element.getElementsByTagName(selector.substring(4));
  }
  if (selector.startsWith('id.')) {
    return element.querySelectorAll('#${selector.substring(3)}');
  }
  if (selector.startsWith('text.')) {
    final needle = selector.substring(5);
    return element.getElementsByTagName('*').where((node) {
      return node.text.contains(needle);
    }).toList();
  }
  try {
    return element.querySelectorAll(selector);
  } catch (_) {
    return const [];
  }
}

({String selector, int? index}) _indexed(String segment) {
  final match = RegExp(r'^(.*)\.(-?\d+)$').firstMatch(segment);
  if (match == null) return (selector: segment, index: null);
  return (selector: match.group(1)!, index: int.parse(match.group(2)!));
}

List<String> _segments(String rule) {
  if (rule.isEmpty) return const [];
  final parts = rule.split('@').where((part) => part.isNotEmpty).toList();
  if (_attribute(rule) != null) parts.removeLast();
  return parts;
}

String? _attribute(String rule) {
  if (!rule.contains('@')) return null;
  final parts = rule.split('@').where((part) => part.isNotEmpty).toList();
  if (parts.length < 2 || !_isAttribute(parts.last)) return null;
  return parts.last;
}

bool _isAttribute(String segment) {
  const named = {'text', 'owntext', 'html', 'textnodes', 'href', 'src', 'all'};
  if (named.contains(segment.toLowerCase())) return true;
  return !segment.contains('.') &&
      !segment.contains(' ') &&
      !segment.contains('[') &&
      !segment.contains('#') &&
      !segment.contains('>');
}

String _readAttribute(Element element, String attribute) {
  switch (attribute.toLowerCase()) {
    case 'text':
    case 'all':
      return element.text.trim();
    case 'owntext':
      return element.nodes
          .whereType<Text>()
          .map((node) => node.text.trim())
          .where((text) => text.isNotEmpty)
          .join('\n');
    case 'html':
      return element.innerHtml;
    case 'textnodes':
      return element.nodes
          .whereType<Text>()
          .map((node) => node.text.trim())
          .where((text) => text.isNotEmpty)
          .join('\n');
    default:
      return element.attributes[attribute] ?? '';
  }
}

String _asText(dynamic value, {required String baseUrl, String? attribute}) {
  if (value is Element) {
    final text = attribute == null
        ? value.text.trim()
        : _readAttribute(value, attribute);
    return _absolutize(text, baseUrl: baseUrl, attribute: attribute);
  }
  if (value == null) return '';
  final text = '$value'.trim();
  return _absolutize(text, baseUrl: baseUrl, attribute: attribute);
}

String _absolutize(String text, {required String baseUrl, String? attribute}) {
  if (text.isEmpty) return '';
  final attr = attribute?.toLowerCase();
  final link =
      attr == 'href' || attr == 'src' || (attr == null && text.startsWith('/'));
  if (!link || text.startsWith('http') || text.startsWith('data:')) return text;
  if (baseUrl.isEmpty) return text;
  return resolveAgainst(baseUrl, text);
}

String resolveAgainst(String baseUrl, String target) {
  if (target.startsWith('//')) return 'https:$target';
  final base = Uri.tryParse(baseUrl);
  if (base == null) return target;
  return base.resolve(target).toString();
}

String _applyReplace(String text, List<String> parts) {
  var result = text;
  for (var i = 1; i < parts.length; i += 2) {
    final pattern = parts[i];
    final replacement = i + 1 < parts.length ? parts[i + 1] : '';
    result = result.replaceAll(RegExp(pattern), replacement);
  }
  return result.trim();
}

String _coreRule(String rule) => rule.split('##').first.trim();

String _selectorRule(String rule) => _coreRule(rule);

bool _jsonRule(String rule, Object document) {
  final core = _coreRule(rule).trim();
  if (core.toLowerCase().startsWith('@json:') || core.startsWith(r'$')) {
    return true;
  }
  return document is Map || document is List;
}

Element? _asElement(Object document) {
  if (document is Element) return document;
  if (document is String) return parse(document).documentElement;
  return null;
}

String _plain(Object document) {
  if (document is Element) return document.text;
  if (document is Map || document is List) return jsonEncode(document);
  return '$document';
}

List<String> _splitOr(String rule) => _splitOp(rule, '||');

List<String> _splitOp(String rule, String op) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var inside = false;
  for (var i = 0; i < rule.length; i++) {
    if (rule.startsWith('##', i)) {
      inside = !inside;
      buffer.write('##');
      i++;
      continue;
    }
    if (!inside && rule.startsWith(op, i)) {
      parts.add(buffer.toString());
      buffer.clear();
      i += op.length - 1;
      continue;
    }
    buffer.write(rule[i]);
  }
  parts.add(buffer.toString());
  return parts.where((part) => part.trim().isNotEmpty).toList();
}
