import 'package:html/dom.dart';

const _blockTags = {
  'p',
  'div',
  'br',
  'hr',
  'li',
  'tr',
  'article',
  'dd',
  'dt',
  'section',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
};

const _hiddenTags = {'script', 'style', 'noscript'};

/// 当前节点上的文字，不含子元素。
String legadoDirectText(Element element) => element.nodes
    .whereType<Text>()
    .map((node) => node.text.trim())
    .where((text) => text.isNotEmpty)
    .join('\n');

/// 正文。段落和 `<br>` 换行，脚本和整块目录链接不计入。
String legadoVisibleText(Element element) => _blockText(element);

String _blockText(Node node) {
  final buffer = StringBuffer();
  var lineStart = true;

  void breakLine() {
    if (lineStart) return;
    buffer.write('\n');
    lineStart = true;
  }

  void walk(Node current, {required bool root}) {
    if (current is Text) {
      final text = current.data.replaceAll('\u00A0', ' ');
      if (text.trim().isEmpty) return;
      buffer.write(text);
      lineStart = false;
      return;
    }
    if (current is! Element) return;
    final tag = current.localName?.toLowerCase() ?? '';
    if (_hiddenTags.contains(tag)) return;
    if (!root && _isLinkList(current)) return;
    final block = _blockTags.contains(tag);
    if (block) breakLine();
    for (final child in current.nodes) {
      walk(child, root: false);
    }
    if (block) breakLine();
  }

  walk(node, root: true);
  return buffer.toString().trim();
}

/// 一排章节链接不是正文。至少四个链接，并且文字几乎都在链接里。
bool _isLinkList(Element element) {
  final anchors = element.getElementsByTagName('a');
  if (anchors.length < 4) return false;
  final linkChars = anchors.fold<int>(
    0,
    (sum, anchor) => sum + anchor.text.trim().length,
  );
  final total = element.text.trim().length;
  return total > 0 && linkChars * 5 >= total * 4;
}
