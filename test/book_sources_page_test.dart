import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/legado/book_source.dart';
import 'package:fqapp/legado/book_source_store.dart';
import 'package:fqapp/pages/book_sources_page.dart';

void main() {
  testWidgets('pasted legado json shows up as a source', (tester) async {
    final store = MemoryBookSourceRepository();
    await tester.pumpWidget(
      MaterialApp(home: BookSourcesPage(repository: store)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有书源'), findsOneWidget);

    await tester.tap(find.byKey(const Key('book-source-import')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('book-source-import-field')),
      '{"bookSourceUrl":"https://ex.com","bookSourceName":"示例书源"}',
    );
    await tester.tap(find.byKey(const Key('book-source-import-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('示例书源'), findsOneWidget);
    expect(store.items.single.name, '示例书源');
    expect(find.textContaining('还没有书源'), findsNothing);
  });
}
