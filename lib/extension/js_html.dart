import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

/// `HtmlDocument` 的 Dart 侧：JS 只拿到元素/节点的整数句柄，查询都在这里做。
///
/// 协议与 Venera（GPL-3.0）`DocumentWrapper` 一致，扩展脚本不用改。
class JsHtmlDocuments {
  /// 同时存活的文档上限；脚本忘了 dispose 时丢掉最早的一份。
  static const maxDocuments = 8;

  final _documents = <int, _JsDocument>{};

  Object? handle(Map<String, dynamic> data) {
    final function = data['function'];
    if (function == 'parse') {
      if (_documents.length >= maxDocuments) {
        _documents.remove(_documents.keys.first);
      }
      _documents[data['key'] as int] = _JsDocument(
        html.parse('${data['data'] ?? ''}'),
      );
      return null;
    }
    if (function == 'dispose') {
      _documents.remove(data['key']);
      return null;
    }
    if (function == 'querySelector' ||
        function == 'querySelectorAll' ||
        function == 'getElementById') {
      final doc = _doc(data['key']);
      return switch (function) {
        'querySelector' => doc.keep(doc.root.querySelector('${data['query']}')),
        'querySelectorAll' => doc.keepAll(
          doc.root.querySelectorAll('${data['query']}'),
        ),
        _ => doc.keep(doc.root.getElementById('${data['id']}')),
      };
    }
    final doc = _doc(data['doc']);
    final key = data['key'] as int;
    switch (function) {
      case 'getText':
        return doc.elements[key].text;
      case 'getAttributes':
        return doc.elements[key].attributes.map(
          (name, value) => MapEntry(name.toString(), value),
        );
      case 'dom_querySelector':
        return doc.keep(doc.elements[key].querySelector('${data['query']}'));
      case 'dom_querySelectorAll':
        return doc.keepAll(
          doc.elements[key].querySelectorAll('${data['query']}'),
        );
      case 'getChildren':
        return doc.keepAll(doc.elements[key].children);
      case 'getNodes':
        return doc.keepNodes(doc.elements[key].nodes);
      case 'getInnerHTML':
        return doc.elements[key].innerHtml;
      case 'getParent':
        return doc.keep(doc.elements[key].parent);
      case 'node_text':
        return doc.nodes[key].text;
      case 'node_type':
        return switch (doc.nodes[key].nodeType) {
          dom.Node.ELEMENT_NODE => 'element',
          dom.Node.TEXT_NODE => 'text',
          dom.Node.COMMENT_NODE => 'comment',
          dom.Node.DOCUMENT_NODE => 'document',
          _ => 'unknown',
        };
      case 'node_to_element':
        final node = doc.nodes[key];
        return node is dom.Element ? doc.keep(node) : null;
      case 'getClassNames':
        return doc.elements[key].classes.toList();
      case 'getId':
        return doc.elements[key].id;
      case 'getLocalName':
        return doc.elements[key].localName;
      case 'getPreviousSibling':
        return doc.keep(doc.elements[key].previousElementSibling);
      case 'getNextSibling':
        return doc.keep(doc.elements[key].nextElementSibling);
    }
    return null;
  }

  _JsDocument _doc(Object? key) {
    final doc = _documents[key];
    if (doc == null) throw StateError('HtmlDocument $key 已释放');
    return doc;
  }
}

class _JsDocument {
  _JsDocument(this.root);

  final dom.Document root;
  final elements = <dom.Element>[];
  final nodes = <dom.Node>[];

  int? keep(dom.Element? element) {
    if (element == null) return null;
    elements.add(element);
    return elements.length - 1;
  }

  List<int> keepAll(Iterable<dom.Element> found) => [
    for (final element in found) keep(element)!,
  ];

  List<int> keepNodes(Iterable<dom.Node> found) {
    final keys = <int>[];
    for (final node in found) {
      nodes.add(node);
      keys.add(nodes.length - 1);
    }
    return keys;
  }
}
