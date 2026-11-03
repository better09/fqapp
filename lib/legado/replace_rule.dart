/// 阅读的 `##正则##替换`。
///
/// 只有一对时替换全部。末尾再加一个 `##` 时只取出第一处匹配并替换，
/// 没匹配到就得到空字符串，用来从整页里抠出正文。
String legadoReplace(String text, List<String> parts) {
  if (parts.length < 2 || parts[1].isEmpty) return text.trim();
  final pattern = parts[1];
  final replacement = parts.length > 2 ? parts[2] : '';
  final firstOnly = parts.length > 3;
  final regex = _compile(pattern);
  if (regex == null) {
    if (firstOnly) return _unescapeJs(replacement);
    return _unescapeJs(text.replaceAll(pattern, replacement)).trim();
  }
  if (firstOnly) {
    final match = regex.firstMatch(text);
    if (match == null) return '';
    return _unescapeJs(_fillGroups(match, replacement)).trim();
  }
  return _unescapeJs(
    text.replaceAllMapped(regex, (match) => _fillGroups(match, replacement)),
  ).trim();
}

RegExp? _compile(String pattern) {
  var source = pattern;
  var caseSensitive = true;
  var dotAll = false;
  final flags = RegExp(r'^\(\?([a-z]+)\)').firstMatch(source);
  if (flags != null) {
    final set = flags.group(1)!;
    if (set.contains('i')) caseSensitive = false;
    if (set.contains('s')) dotAll = true;
    source = source.substring(flags.end);
  }
  try {
    return RegExp(source, caseSensitive: caseSensitive, dotAll: dotAll);
  } catch (_) {
    return null;
  }
}

String _fillGroups(Match match, String replacement) {
  final buffer = StringBuffer();
  for (var i = 0; i < replacement.length; i++) {
    if (replacement.startsWith(r'$$', i)) {
      buffer.write(r'$');
      i++;
      continue;
    }
    if (replacement[i] == r'$' && i + 1 < replacement.length) {
      final digit = replacement.codeUnitAt(i + 1);
      if (digit >= 0x30 && digit <= 0x39) {
        buffer.write(match.group(digit - 0x30) ?? '');
        i++;
        continue;
      }
    }
    buffer.write(replacement[i]);
  }
  return buffer.toString();
}

String _unescapeJs(String text) {
  if (!text.contains(r'\')) return text;
  return text
      .replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (match) {
        final code = int.tryParse(match.group(1)!, radix: 16);
        return code == null ? match.group(0)! : String.fromCharCode(code);
      })
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '')
      .replaceAll(r'\t', ' ')
      .replaceAll(r'\/', '/')
      .replaceAll(r'\"', '"')
      .replaceAll(r"\'", "'");
}
