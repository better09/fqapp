import 'dart:async';

import '../models/media_item.dart';
import 'comic_extension.dart';
import 'extension_store.dart';

const _searchTimeout = Duration(seconds: 25);

/// 一轮扩展搜索的进度：每个扩展返回一次就回调一次。
class ExtensionSearchProgress {
  const ExtensionSearchProgress({
    required this.items,
    required this.errors,
    required this.finished,
    required this.total,
  });

  final List<MediaItem> items;
  final List<String> errors;
  final int finished;
  final int total;
}

/// 同时用多个漫画源扩展搜索。单个扩展失败只记一条错误，不影响其他扩展。
Future<ExtensionSearchProgress> searchComicExtensions({
  required ComicExtensionClient client,
  required List<InstalledComicExtension> extensions,
  required String keyword,
  bool Function()? isCancelled,
  void Function(ExtensionSearchProgress progress)? onProgress,
}) async {
  final items = <MediaItem>[];
  final errors = <String>[];
  var finished = 0;
  ExtensionSearchProgress snapshot() => ExtensionSearchProgress(
    items: List.unmodifiable(items),
    errors: List.unmodifiable(errors),
    finished: finished,
    total: extensions.length,
  );

  await Future.wait([
    for (final extension in extensions)
      client
          .search(extension.key, keyword)
          .timeout(_searchTimeout)
          .then(
            (found) => items.addAll(found.map((comic) => comic.toMediaItem())),
            onError: (Object error, StackTrace _) {
              final message = error is TimeoutException ? '请求超时' : '$error';
              errors.add('${extension.name}：$message');
            },
          )
          .whenComplete(() {
            finished++;
            if (isCancelled?.call() != true) onProgress?.call(snapshot());
          }),
  ]);
  return snapshot();
}
