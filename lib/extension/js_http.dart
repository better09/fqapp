import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../legado/analyze_url.dart' show legadoDefaultUserAgent;
import '../legado/charset.dart';

const _requestTimeout = Duration(seconds: 20);

/// 扩展脚本共用的 Cookie：按域名存 name → value，变化时回调持久化。
class JsCookieJar {
  JsCookieJar([Map<String, Map<String, String>>? initial, this.onChanged])
    : _hosts = {
        for (final entry in (initial ?? const {}).entries)
          entry.key: Map.of(entry.value),
      };

  final Map<String, Map<String, String>> _hosts;
  final void Function(Map<String, Map<String, String>> hosts)? onChanged;

  Map<String, Map<String, String>> get snapshot => {
    for (final entry in _hosts.entries) entry.key: Map.of(entry.value),
  };

  Iterable<String> _matching(String host) => _hosts.keys.where(
    (domain) => host == domain || host.endsWith('.$domain'),
  );

  String? header(Uri uri) {
    final pairs = <String, String>{};
    for (final domain in _matching(uri.host)) {
      pairs.addAll(_hosts[domain]!);
    }
    if (pairs.isEmpty) return null;
    return pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void set(Uri uri, String name, String value, {String? domain}) {
    var host = (domain ?? uri.host).trim();
    if (host.startsWith('.')) host = host.substring(1);
    if (host.isEmpty || name.isEmpty) return;
    _hosts.putIfAbsent(host, () => {})[name] = value;
  }

  /// `Network.setCookies` / `getCookies` / `deleteCookies`。
  Object? handle(Map<String, dynamic> data) {
    final uri = Uri.tryParse('${data['url']}');
    if (uri == null || uri.host.isEmpty) return null;
    switch (data['function']) {
      case 'set':
        for (final cookie in (data['cookies'] as List? ?? const [])) {
          if (cookie is! Map) continue;
          set(
            uri,
            '${cookie['name'] ?? ''}',
            '${cookie['value'] ?? ''}',
            domain: cookie['domain']?.toString(),
          );
        }
        onChanged?.call(snapshot);
        return null;
      case 'get':
        return [
          for (final domain in _matching(uri.host))
            for (final entry in _hosts[domain]!.entries)
              {
                'name': entry.key,
                'value': entry.value,
                'domain': domain,
                'path': '/',
                'session': true,
              },
        ];
      case 'delete':
        _hosts.removeWhere((domain, _) => _matching(uri.host).contains(domain));
        onChanged?.call(snapshot);
        return null;
    }
    return null;
  }

  void absorb(Uri uri, String? setCookie) {
    if (setCookie == null || setCookie.isEmpty) return;
    var changed = false;
    for (final part in setCookie.split(RegExp(r',(?=\s*[^;,=\s]+=)'))) {
      final attributes = part.split(';');
      final pair = attributes.first.split('=');
      if (pair.length < 2) continue;
      String? domain;
      for (final attribute in attributes.skip(1)) {
        final kv = attribute.split('=');
        if (kv.first.trim().toLowerCase() == 'domain' && kv.length > 1) {
          domain = kv[1].trim();
        }
      }
      set(uri, pair.first.trim(), pair.skip(1).join('=').trim(), domain: domain);
      changed = true;
    }
    if (changed) onChanged?.call(snapshot);
  }
}

/// `Network.sendRequest` / `fetchBytes` 的 Dart 侧，返回值形如
/// `{status, headers, body, error}`，与 Venera 一致。
class JsHttp {
  JsHttp(this.cookies, {http.Client Function()? client})
    : _client = client ?? http.Client.new;

  final JsCookieJar cookies;
  final http.Client Function() _client;

  Future<Map<String, dynamic>> send(Map<String, dynamic> request) async {
    final client = _client();
    try {
      final uri = Uri.parse('${request['url']}');
      final outgoing = http.Request(
        '${request['http_method'] ?? 'GET'}'.toUpperCase(),
        uri,
      );
      final headers = <String, String>{
        for (final entry in ((request['headers'] as Map?) ?? const {}).entries)
          '${entry.key}': '${entry.value}',
      };
      if (!headers.keys.any((name) => name.toLowerCase() == 'user-agent')) {
        headers['User-Agent'] = legadoDefaultUserAgent;
      }
      final cookie = cookies.header(uri);
      if (cookie != null &&
          !headers.keys.any((name) => name.toLowerCase() == 'cookie')) {
        headers['Cookie'] = cookie;
      }
      _attachBody(outgoing, headers, request['data']);
      outgoing.headers.addAll(headers);
      final response = await client.send(outgoing).timeout(_requestTimeout);
      final bytes = await response.stream.toBytes().timeout(_requestTimeout);
      cookies.absorb(uri, response.headers['set-cookie']);
      return {
        'status': response.statusCode,
        'headers': response.headers,
        'body': request['bytes'] == true
            ? bytes
            : decodeLegadoBytes(
                bytes,
                contentType: response.headers['content-type'],
              ),
        'error': null,
      };
    } catch (error) {
      return {'status': null, 'headers': {}, 'body': null, 'error': '$error'};
    } finally {
      client.close();
    }
  }

  static void _attachBody(
    http.Request outgoing,
    Map<String, String> headers,
    Object? data,
  ) {
    if (data == null) return;
    final contentType = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'content-type')
        .map((entry) => entry.value.toLowerCase())
        .firstOrNull;
    if (data is Uint8List) {
      outgoing.bodyBytes = data;
    } else if (data is List<int>) {
      outgoing.bodyBytes = Uint8List.fromList(data);
    } else if (data is String) {
      outgoing.bodyBytes = utf8.encode(data);
    } else if (data is Map &&
        (contentType?.contains('x-www-form-urlencoded') ?? false)) {
      outgoing.bodyBytes = utf8.encode(
        data.entries
            .map(
              (entry) =>
                  '${Uri.encodeQueryComponent('${entry.key}')}='
                  '${Uri.encodeQueryComponent('${entry.value}')}',
            )
            .join('&'),
      );
    } else {
      outgoing.bodyBytes = utf8.encode(jsonEncode(data));
      if (contentType == null) headers['Content-Type'] = 'application/json';
    }
  }
}
