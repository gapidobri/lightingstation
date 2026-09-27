import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightingstation/screens/console_screen.dart';
import 'package:lightingstation/session.dart';

void main() {
  Widget host(ConsoleSession session) => WidgetsApp(
    color: const Color(0xFF000000),
    pageRouteBuilder: <T>(settings, builder) =>
        PageRouteBuilder<T>(settings: settings, pageBuilder: (context, _, _) => builder(context)),
    home: ConsoleScreen(session: session, onDisconnect: () {}),
  );

  testWidgets('dragging a playback fader raises its level', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = DemoSession();
    await tester.pumpWidget(host(session));

    expect(find.text('PB 1'), findsOneWidget);
    expect(find.text('PB 10'), findsOneWidget);

    final fader = find.bySemanticsLabel('Playback 1 level');
    await tester.drag(fader, const Offset(0, -200));
    await tester.pump();
    expect(session.playbackLevels[0], greaterThan(0.2));
    expect(session.playbackLevels[1], 0);
  });

  testWidgets('execute view shows the page and toggles items', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = DemoSession();
    await tester.pumpWidget(host(session));

    await tester.tap(find.text('Execute'));
    await tester.pump();
    expect(find.text('Execute page 1, Main'), findsOneWidget);

    await tester.tap(find.text('Warm wash'));
    await tester.pump();
    expect(session.executePage!.items.first.active, isTrue);
  });
}
