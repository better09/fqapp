import 'package:http/http.dart' as http;

import 'book_source.dart';
import 'rules.dart';

const sourceCheckConcurrency = 6;
const sourceCheckTimeout = Duration(seconds: 6);

typedef SourceProbe = Future<bool> Function(LegadoBookSource source);

class SourceCheckProgress {
  final int finished;
  final int total;
  final int usable;
  final int disabled;

  const SourceCheckProgress({
    required this.finished,
    required this.total,
    required this.usable,
    required this.disabled,
  });
}

/// 当前引擎跑不了的书源：不是文字书、缺搜索规则，或规则里有 JavaScript。
String? sourceUnusableReason(LegadoBookSource source) {
  if (source.type != 0) return 'skip';
  final searchUrl = source.searchUrl;
  if (searchUrl == null || searchUrl.trim().isEmpty) return 'skip';
  if ((source.search.bookList ?? '').trim().isEmpty) return 'skip';
  if (_usesJs(source)) return 'js';
  return null;
}

bool _usesJs(LegadoBookSource source) =>
    legadoRuleUsesJs(source.searchUrl) ||
    legadoRuleUsesJs(source.search.bookList) ||
    legadoRuleUsesJs(source.search.name) ||
    legadoRuleUsesJs(source.search.bookUrl) ||
    legadoRuleUsesJs(source.toc.chapterList) ||
    legadoRuleUsesJs(source.toc.chapterName) ||
    legadoRuleUsesJs(source.toc.chapterUrl) ||
    legadoRuleUsesJs(source.content.content);

/// 校验书源：无用的停用并记下原因，不删除。站点有响应（含 404）算可用。
Future<List<LegadoBookSource>> verifyBookSources(
  List<LegadoBookSource> sources, {
  SourceProbe? probe,
  void Function(SourceCheckProgress progress)? onProgress,
}) async {
  final next = [...sources];
  var finished = 0;
  var usable = 0;
  var disabled = 0;
  void report() {
    onProgress?.call(
      SourceCheckProgress(
        finished: finished,
        total: sources.length,
        usable: usable,
        disabled: disabled,
      ),
    );
  }

  var index = 0;
  Future<void> worker() async {
    while (true) {
      final current = index++;
      if (current >= next.length) return;
      final source = next[current];
      final reason = sourceUnusableReason(source);
      if (reason != null) {
        next[current] = source.withCheck(reason, enabled: false);
        disabled++;
      } else {
        final alive = await (probe ?? probeBookSource)(source);
        next[current] = source.withCheck(
          alive ? 'ok' : 'fail',
          enabled: alive && source.enabled,
        );
        if (alive && source.enabled) {
          usable++;
        } else {
          disabled++;
        }
      }
      finished++;
      report();
    }
  }

  final workers = sources.isEmpty
      ? 0
      : sources.length < sourceCheckConcurrency
      ? sources.length
      : sourceCheckConcurrency;
  if (workers > 0) {
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  }
  report();
  return next;
}

Future<bool> probeBookSource(LegadoBookSource source) async {
  final uri = Uri.tryParse(source.url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  final client = http.Client();
  try {
    final response = await client
        .get(uri, headers: const {'User-Agent': 'Mozilla/5.0'})
        .timeout(sourceCheckTimeout);
    return response.statusCode < 500;
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}
