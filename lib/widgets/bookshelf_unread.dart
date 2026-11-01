import 'package:flutter/material.dart';

import 'home/home_design.dart';
import 'shelf/shelf_design.dart';

/// 未读章数的高亮色：墨水屏没有彩色，退回墨色加粗。
Color bookshelfUnreadColor(HomePalette palette) =>
    palette.eink ? palette.ink : HomePalette.accent;

/// 一行副信息：「N章未读」高亮在前，其余信息灰色跟在后面。
class BookshelfInfoLine extends StatelessWidget {
  final String? unreadText;
  final String? infoText;

  const BookshelfInfoLine({super.key, this.unreadText, this.infoText});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final unread = unreadText;
    final info = infoText;
    return Text.rich(
      TextSpan(
        children: [
          if (unread != null)
            TextSpan(
              text: unread,
              style: TextStyle(
                color: bookshelfUnreadColor(palette),
                fontWeight: FontWeight.w600,
              ),
            ),
          if (unread != null && info != null) const TextSpan(text: ' · '),
          if (info != null) TextSpan(text: info),
        ],
      ),
      key: const Key('bookshelf-info-line'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: ShelfTokens.subtitle,
        height: ShelfTokens.subtitleLineHeight,
        color: palette.muted,
      ),
    );
  }
}

/// 双列卡片底部的小标签：有未读章时高亮「N章未读」，否则是作品类型
/// （kind 色 12% 底，数据真实存在，非装饰）。
class BookshelfTag extends StatelessWidget {
  final String kind;
  final String? unreadText;

  const BookshelfTag({super.key, required this.kind, this.unreadText});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final unread = unreadText;
    final color = unread != null
        ? bookshelfUnreadColor(palette)
        : bookshelfKindColor(kind) ?? palette.muted;
    return SizedBox(
      height: shelfKindTagHeight(context),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(ShelfTokens.kindTagSize),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: ShelfTokens.spaceS),
          child: Text(
            unread ?? bookshelfKindLabel(kind),
            maxLines: 1,
            style: TextStyle(
              fontSize: ShelfTokens.kindTagSize,
              height: 1.2,
              fontWeight: unread != null ? FontWeight.w700 : FontWeight.w500,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
