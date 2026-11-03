/// 把常见的 XPath（`//div[@id='content']/text()`）收成 CSS，复杂谓词保持原样。
String? xpathToCss(String rule) {
  var text = rule.trim();
  final lower = text.toLowerCase();
  if (lower.startsWith('@xpath:')) {
    text = text.substring(7).trim();
  } else if (!text.startsWith('/')) {
    return null;
  }
  var asText = false;
  final textNode = RegExp(r'/+text\(\)\s*$').firstMatch(text);
  if (textNode != null) {
    asText = true;
    text = text.substring(0, textNode.start);
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
  if (selector.isEmpty) return null;
  return asText ? '$selector@text' : selector;
}
