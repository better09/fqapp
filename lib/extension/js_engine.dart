import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:http/http.dart' as http;

import 'extension_store.dart';
import 'js_convert.dart';
import 'js_html.dart';
import 'js_http.dart';

/// 脚本看到的 `APP.version`。扩展用 `minAppVersion` 对照 Venera 的版本号，
/// 这里报和本运行时（Venera 的 init.js）对应的那一版。
const veneraCompatibleVersion = '1.6.3';

typedef ExtensionRuntimeSource = Future<String> Function();

Future<String> _bundledRuntime() => rootBundle.loadString('assets/venera/init.js');

/// 宿主补充的脚本：取图时一并处理 `onImageLoad` 的请求改写和 `onResponse`。
const _hostHelpers = r'''
globalThis.__fqImage = async function (key, url, comicId, epId) {
  const source = ComicSource.sources[key];
  const comic = source && source.comic;
  let config = null;
  if (comic && typeof comic.onImageLoad === 'function') {
    config = await comic.onImageLoad(url, comicId, epId);
  }
  config = config || {};
  const request = {
    url: config.url || url,
    method: config.method || 'GET',
    headers: config.headers || {},
    data: config.data === undefined ? null : config.data,
  };
  if (typeof config.onResponse !== 'function') return { request: request };
  const res = await Network.fetchBytes(
    request.method, request.url, request.headers, request.data);
  return { bytes: await config.onResponse(res.body) };
};
''';

/// 一个 QuickJS 实例，加载 Venera 的 init.js，回答脚本的 `sendMessage`。
///
/// 所有扩展共用这一个实例（和 Venera 相同），各自挂在 `ComicSource.sources`。
class ComicJsEngine {
  ComicJsEngine({
    required this.store,
    ExtensionRuntimeSource? runtime,
    this.client,
  }) : _runtime = runtime ?? _bundledRuntime;

  final ComicExtensionStore store;
  final ExtensionRuntimeSource _runtime;
  final http.Client Function()? client;
  final _html = JsHtmlDocuments();
  final _data = <String, Map<String, dynamic>>{};
  final _settingDefaults = <String, Map<String, dynamic>>{};
  JsHttp? _http;
  FlutterQjs? _qjs;
  Future<void>? _ready;

  /// 脚本调用 `UI.showMessage` 时的提示出口。
  void Function(String message)? onMessage;

  JsHttp get httpBridge => _http!;

  Future<void> ready() => _ready ??= _start();

  Future<void> _start() async {
    final cookies = JsCookieJar(
      await store.loadCookies(),
      (hosts) => unawaited(store.saveCookies(hosts)),
    );
    _http = JsHttp(cookies, client: client);
    final qjs = FlutterQjs(stackSize: 4 << 20);
    unawaited(qjs.dispatch());
    final setGlobal =
        qjs.evaluate('(key, value) => { globalThis[key] = value; }')
            as JSInvokable;
    setGlobal.invoke(['sendMessage', _receive]);
    setGlobal.invoke(['appVersion', veneraCompatibleVersion]);
    setGlobal.free();
    qjs.evaluate(await _runtime(), name: '<venera-init>');
    qjs.evaluate(_hostHelpers, name: '<fqapp-host>');
    _qjs = qjs;
  }

  /// 同步执行；结果是 Promise 时返回 Dart [Future]。
  dynamic run(String code, {String name = '<eval>'}) {
    final qjs = _qjs;
    if (qjs == null) throw StateError('JS 引擎还没启动');
    return qjs.evaluate(code, name: name);
  }

  /// 执行并等待 Promise。
  Future<dynamic> evaluate(String code, {String name = '<eval>'}) async {
    await ready();
    final result = run(code, name: name);
    return result is Future ? await result : result;
  }

  /// 调用 `ComicSource.sources[key]` 上的一个成员函数，参数按 JSON 传入。
  Future<dynamic> callSource(String key, String path, List<Object?> args) =>
      evaluate(
        'ComicSource.sources[${jsonEncode(key)}].$path'
        '(${args.map(jsonEncode).join(', ')})',
        name: '<$key.$path>',
      );

  Future<void> attachData(String key, Map<String, dynamic> settings) async {
    _data[key] = await store.loadData(key);
    _settingDefaults[key] = settings;
  }

  void detach(String key) {
    _data.remove(key);
    _settingDefaults.remove(key);
    if (_qjs != null) run('delete ComicSource.sources[${jsonEncode(key)}]');
  }

  Object? _receive(dynamic message) {
    if (message is! Map) return null;
    final data = Map<String, dynamic>.from(message);
    final key = '${data['key'] ?? ''}';
    switch (data['method']) {
      case 'load_data':
        return _data[key]?[data['data_key']];
      case 'save_data':
        if (data['data_key'] == 'setting') {
          throw 'setting is not allowed to be saved';
        }
        (_data[key] ??= {})['${data['data_key']}'] = data['data'];
        _persist(key);
        return null;
      case 'delete_data':
        _data[key]?.remove(data['data_key']);
        _persist(key);
        return null;
      case 'load_setting':
        final name = data['setting_key'];
        final saved = _data[key]?['settings'];
        if (saved is Map && saved.containsKey(name)) return saved[name];
        final declared = _settingDefaults[key]?[name];
        return declared is Map ? declared['default'] : null;
      case 'isLogged':
        return _data[key]?['account'] != null;
      case 'http':
        return httpBridge.send(data);
      case 'html':
        return _html.handle(data);
      case 'convert':
        return jsConvert(data);
      case 'random':
        return jsRandom(data['min'], data['max'], data['type']);
      case 'cookie':
        return httpBridge.cookies.handle(data);
      case 'uuid':
        return jsUuid();
      case 'delay':
        final time = data['time'];
        return Future<void>.delayed(
          Duration(milliseconds: time is num ? time.toInt() : 0),
        );
      case 'getLocale':
        return 'zh_CN';
      case 'getPlatform':
        return Platform.operatingSystem;
      case 'setClipboard':
        return Clipboard.setData(ClipboardData(text: '${data['text']}'));
      case 'getClipboard':
        return Clipboard.getData(
          Clipboard.kTextPlain,
        ).then((value) => value?.text);
      case 'UI':
        if (data['function'] == 'showMessage') {
          onMessage?.call('${data['message']}');
        }
        return null;
      case 'compute':
        return _compute(data['function'], data['args']);
      case 'log':
        return null;
    }
    return null;
  }

  Object? _compute(Object? function, Object? args) {
    if (function is! String) throw 'Function must be a string';
    final invokable = run('($function)', name: '<compute>');
    if (invokable is! JSInvokable) throw 'compute 需要一个函数';
    try {
      return invokable.invoke(args is List ? args : const []);
    } finally {
      invokable.free();
    }
  }

  void _persist(String key) {
    final data = _data[key];
    if (data == null) return;
    try {
      jsonEncode(data);
    } catch (_) {
      return;
    }
    unawaited(store.saveData(key, data));
  }

  void dispose() {
    final qjs = _qjs;
    _qjs = null;
    _ready = null;
    qjs?.port.close();
    qjs?.close();
  }
}
