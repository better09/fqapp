import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/legado/book_source.dart';
import 'package:fqapp/legado/source_check.dart';

void main() {
  test('verification disables script, empty and dead sources', () async {
    final sources = [
      _source('https://ok.example', '可用', bookList: '.book'),
      _source('https://dead.example', '无响应', bookList: '.book'),
      _source('https://js.example', '脚本', bookList: '@js:[]'),
      _source('https://audio.example', '有声', bookList: '.book', type: 1),
      _source('https://empty.example', '缺规则'),
    ];

    final checked = await verifyBookSources(
      sources,
      probe: (source) async => source.url.contains('ok.example'),
    );

    expect(checked[0].checkedOk, isTrue);
    expect(checked[0].enabled, isTrue);
    expect(checked[1].checkStatus, 'fail');
    expect(checked[1].enabled, isFalse);
    expect(checked[2].checkStatus, 'js');
    expect(checked[2].enabled, isFalse);
    expect(checked[3].checkStatus, 'skip');
    expect(checked[3].enabled, isFalse);
    expect(checked[4].checkStatus, 'skip');
    expect(checked[4].enabled, isFalse);
  });
}

LegadoBookSource _source(
  String url,
  String name, {
  String bookList = '',
  int type = 0,
}) => LegadoBookSource({
  'bookSourceUrl': url,
  'bookSourceName': name,
  'bookSourceType': type,
  'enabled': true,
  'searchUrl': 'https://example/search',
  'ruleSearch': {'bookList': bookList, 'name': 'a'},
});
