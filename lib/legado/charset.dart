import 'dart:convert';

import 'package:enough_convert/enough_convert.dart';

const _gbk = GbkCodec(allowInvalid: true);
const _big5 = Big5Codec(allowInvalid: true);

/// 按书源声明、响应头或网页里的 charset 解码。很多小说站是 GBK，
/// 按 UTF-8 硬解会变成乱码，正文规则就匹配不到。
String decodeLegadoBytes(
  List<int> bytes, {
  String? charset,
  String? contentType,
}) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  final name =
      _normalize(charset) ??
      _normalize(_headerCharset(contentType)) ??
      _normalize(_metaCharset(bytes));
  if (name != null) return _decode(bytes, name);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return _decode(bytes, 'gbk');
  }
}

String? _headerCharset(String? contentType) {
  if (contentType == null) return null;
  return RegExp(
    r'charset\s*=\s*"?([^";\s]+)',
    caseSensitive: false,
  ).firstMatch(contentType)?.group(1);
}

String? _metaCharset(List<int> bytes) {
  final head = latin1.decode(
    bytes.length > 8192 ? bytes.sublist(0, 8192) : bytes,
  );
  return RegExp(
    r'''charset\s*=\s*["']?\s*([A-Za-z0-9._-]+)''',
    caseSensitive: false,
  ).firstMatch(head)?.group(1);
}

String? _normalize(String? name) {
  if (name == null) return null;
  final lower = name.trim().toLowerCase().replaceAll('_', '-');
  if (lower.isEmpty) return null;
  return switch (lower) {
    'utf8' || 'utf-8' => 'utf-8',
    'gbk' || 'gb2312' || 'gb-2312' || 'gb18030' || 'gb-18030' => 'gbk',
    'big5' || 'big-5' || 'cp950' => 'big5',
    'latin1' || 'iso-8859-1' || 'windows-1252' => 'latin1',
    _ => lower,
  };
}

String _decode(List<int> bytes, String name) {
  switch (name) {
    case 'utf-8':
      return utf8.decode(bytes, allowMalformed: true);
    case 'gbk':
      return _gbk.decode(bytes);
    case 'big5':
      return _big5.decode(bytes);
    case 'latin1':
      return latin1.decode(bytes);
    default:
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return _gbk.decode(bytes);
      }
  }
}
