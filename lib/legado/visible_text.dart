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

/// 当前节点上的文字，不含子元素。
String legadoDirectText(Element element) => element.nodes
    .whereType<Text>()
    .map((node) => node.text.trim())
    .where((text) => text.isNotEmpty)
    .join('\n');

/// 正文。`<br>` 和段落会换行，`<script>` / `<style>` 丢掉。
///
/// 直接文字已经是一整章时（用 `<br>` 分段的页面）不再把子元素里的目录链接拼进来。
/// 直接文字只是章节标题、正文在 `<p>` 里时，要带上这些段落，否则阅读器会当成没有正文。
String legadoVisibleText(Element element) {
  final direct = legadoDirectText(element);
  final blocks = _blockText(element);
  if (direct.length >= 80) return direct;
  return blocks.length >= direct.length ? blocks : direct;
}

String _blockText(Node node) {
  final buffer = StringBuffer();
  var lineStart = true;

  void breakLine() {
    if (lineStart) return;
    buffer.write('\n');
    lineStart = true;
  }

  void walk(Node current) {
    if (current is Text) {
      final text = current.data.replaceAll('\u00A0', ' ');
      if (text.trim().isEmpty) return;
      buffer.write(text);
      lineStart = false;
      return;
    }
    if (current is! Element) return;
    final tag = current.localName?.toLowerCase() ?? '';
    if (tag == 'script' || tag == 'style') return;
    final block = _blockTags.contains(tag);
    if (block) breakLine();
    for (final child in current.nodes) {
      walk(child);
    }
    if (block) breakLine();
  }

  walk(node);
  return buffer.toString().trim();
}
