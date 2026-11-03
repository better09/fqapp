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
  final prepared = _prepareRule(rule);
  if (_jsonRule(prepared, document)) {
    return _jsonNodes(_jsonValues(document, prepared));
  }
  final root = _asElement(document);
  if (root == null) return const [];
  return _htmlElements(root, prepared);
}

List<String> _textsOf(Object document, String rule, {required String baseUrl}) {
  final parts = rule.split('##');
  final core = _prepareRule(parts.first.trim());
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
  final elements = _htmlElements(root, rule);
  if (attribute == null) return elements;
  return elements.map((element) => _readAttribute(element, attribute)).toList();
}

List<Element> _oneSegment(Element element, String segment) {
  final indexed = _indexed(segment);
  final selected = _select(element, indexed.selector);
  final spec = indexed.spec;
  if (spec == null) return selected;
  return _pick(selected, spec);
}

/// 阅读的 `tag.` / `class.` / `id.` 会算上当前元素自己。
/// `package:html` 的 query 只看子孙，目录节点本身是 `<a>` 时会一个章节都选不中。
List<Element> _select(Element element, String selector) {
  if (selector.isEmpty || selector == 'children') {
    return element.children;
  }
  if (selector.startsWith('class.')) {
    final name = selector.substring(6);
    return _include(
      element,
      element.classes.contains(name),
      element.getElementsByClassName(name),
    );
  }
  if (selector.startsWith('tag.')) {
    final name = selector.substring(4).toLowerCase();
    return _include(
      element,
      element.localName?.toLowerCase() == name,
      element.getElementsByTagName(name),
    );
  }
  if (selector.startsWith('id.')) {
    final name = selector.substring(3);
    return _include(element, element.id == name, _css(element, '#$name'));
  }
  if (selector.startsWith('text.')) {
    final needle = selector.substring(5);
    final found = element.getElementsByTagName('*').where((node) {
      return node.text.contains(needle);
    }).toList();
    return _include(element, element.text.contains(needle), found);
  }
  return _css(element, selector);
}

List<Element> _include(Element element, bool self, List<Element> found) {
  if (!self) return found;
  return [element, ...found];
}

List<Element> _css(Element element, String selector) {
  try {
    return element.querySelectorAll(selector);
  } catch (_) {
    return const [];
  }
}

({String selector, String? spec}) _indexed(String segment) {
  final bracket = RegExp(r'^(.*)\[([^\]]+)\]$').firstMatch(segment);
  if (bracket != null && bracket.group(1)!.isNotEmpty) {
    return (selector: bracket.group(1)!, spec: bracket.group(2));
  }
  final dotted = RegExp(r'^(.*)\.(-?\d+(?::-?\d+)*)$').firstMatch(segment);
  if (dotted != null && dotted.group(1)!.isNotEmpty) {
    return (selector: dotted.group(1)!, spec: dotted.group(2));
  }
  return (selector: segment, spec: null);
}

/// `0` 取一个，`-1:0` 从末章排到首章，`0:10:2` 带步长。
List<Element> _pick(List<Element> items, String spec) {
  if (items.isEmpty) return const [];
  final numbers = [
    for (final piece in spec.split(':')) int.tryParse(piece.trim()),
  ];
  if (numbers.any((value) => value == null)) return items;
  int at(int raw) => raw < 0 ? items.length + raw : raw;
  if (numbers.length == 1) {
    final index = at(numbers[0]!);
    if (index < 0 || index >= items.length) return const [];
    return [items[index]];
  }
  int clamp(int raw) {
    final index = at(raw);
    if (index < 0) return 0;
    if (index >= items.length) return items.length - 1;
    return index;
  }

  final start = clamp(numbers[0]!);
  final end = clamp(numbers[1]!);
  var step = numbers.length > 2 ? numbers[2]! : (start <= end ? 1 : -1);
  if (step == 0) step = start <= end ? 1 : -1;
  final out = <Element>[];
  if (step > 0) {
    for (var i = start; i <= end && i < items.length; i += step) {
      out.add(items[i]);
    }
  } else {
    for (var i = start; i >= end && i >= 0; i += step) {
      out.add(items[i]);
    }
  }
  return out;
}

List<String> _segments(String rule) {
  if (rule.isEmpty) return const [];
  final parts = rule.split('@').where((part) => part.isNotEmpty).toList();
  if (_attribute(rule) != null) parts.removeLast();
  return parts;
}

String? _attribute(String rule) {
  final parts = rule.split('@').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty || !_isAttribute(parts.last)) return null;
  if (parts.length == 1 && !_isBareAttribute(parts.single)) return null;
  return parts.last;
}

bool _isBareAttribute(String segment) {
  const named = {'text', 'owntext', 'html', 'textnodes', 'href', 'src', 'all'};
  return named.contains(segment.toLowerCase());
}

bool _isAttribute(String segment) {
  const named = {'text', 'owntext', 'html', 'textnodes', 'href', 'src', 'all'};
  if (named.contains(segment.toLowerCase())) return true;
  return RegExp(r'^[A-Za-z_:][-A-Za-z0-9_:]*$').hasMatch(segment);
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

/// `@CSS:` 和 `@@` 走选择器；`@XPath:` 或以 `/` 开头的规则按常见写法转成 CSS。
String _prepareRule(String rule) {
  var trimmed = rule.trim();
  if (trimmed.contains('{{')) return trimmed;
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('@css:')) {
    trimmed = trimmed.substring(5).trim();
  } else if (trimmed.startsWith('@@')) {
    trimmed = trimmed.substring(2).trim();
  }
  final attribute = _trailingAttribute(trimmed);
  final head = attribute == null
      ? trimmed
      : trimmed.substring(0, trimmed.length - attribute.length - 1).trim();
  final css = _xpathToCss(head);
  if (css == null) return trimmed;
  return attribute == null ? css : '$css@$attribute';
}

String? _trailingAttribute(String rule) {
  final at = rule.lastIndexOf('@');
  if (at <= 0) return null;
  final tail = rule.substring(at + 1);
  if (!_isAttribute(tail)) return null;
  return tail;
}

String? _xpathToCss(String rule) {
  var text = rule.trim();
  final lower = text.toLowerCase();
  if (lower.startsWith('@xpath:')) {
    text = text.substring(7).trim();
  } else if (!text.startsWith('/')) {
    return null;
  }
  text = text.replaceAllMapped(
    RegExp(r"""\[@(class|id)\s*=\s*['"]([^'"]+)['"]\]"""),
    (match) {
      final kind = match.group(1)!.toLowerCase();
      final name = match.group(2)!;
      if (kind == 'id') return '#$name';
      return name
          .split(RegExp(r'\s+'))
          .where((part) => part.isNotEmpty)
          .map((part) => '.$part')
          .join();
    },
  );
  if (text.contains('[') || text.contains('@')) return null;
  final css = StringBuffer();
  var index = 0;
  while (index < text.length) {
    if (text.startsWith('//', index)) {
      if (css.isNotEmpty) css.write(' ');
      index += 2;
      continue;
    }
    if (text[index] == '/') {
      if (css.isNotEmpty) css.write(' > ');
      index++;
      continue;
    }
    final next = text.indexOf('/', index);
    final token =
        (next < 0 ? text.substring(index) : text.substring(index, next)).trim();
    if (token.isNotEmpty) css.write(token == '*' ? '*' : token);
    if (next < 0) break;
    index = next;
  }
  final selector = css.toString().trim();
  return selector.isEmpty ? null : selector;
}

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
