import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/desktop_app_frame.dart';

void main() {
  testWidgets('frame title is 什锦铺; global search stays on every tab', (
    tester,
  ) async {
    desktopTab.value = 0;
    addTearDown(() => desktopTab.value = 0);
    await tester.pumpWidget(
      const MaterialApp(home: DesktopAppFrame(child: SizedBox.expand())),
    );
    await tester.pump();

    expect(find.text('什锦铺'), findsOneWidget);
    expect(find.text('番茄小铺'), findsNothing);
    expect(find.byKey(const Key('desktop-search')), findsOneWidget);
    expect(find.text('书架'), findsOneWidget);
    expect(find.text('书城'), findsOneWidget);
    expect(find.text('短剧'), findsNothing);

    for (final tab in [1, 2, 0]) {
      desktopTab.value = tab;
      await tester.pump();
      expect(find.byKey(const Key('desktop-search')), findsOneWidget);
      expect(find.text('什锦铺'), findsOneWidget);
    }
  });
}
