import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:magicq_remote/magicq_remote.dart';
import 'package:lightingstation/screens/console_screen.dart';
import 'package:lightingstation/session.dart';
import 'package:lightingstation/widgets/console_button.dart';
import 'package:lightingstation/widgets/execute_grid.dart';
import 'package:lightingstation/widgets/playback_strip.dart';

void main() {
  Widget host(ConsoleSession session, {VoidCallback? onDisconnect}) => WidgetsApp(
    color: const Color(0xFF000000),
    pageRouteBuilder: <T>(settings, builder) =>
        PageRouteBuilder<T>(settings: settings, pageBuilder: (context, _, _) => builder(context)),
    home: ConsoleScreen(session: session, onDisconnect: onDisconnect ?? () {}),
  );

  void phone(WidgetTester tester, [Size size = const Size(844, 390)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('dragging a playback fader raises its level', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = DemoSession();
    await tester.pumpWidget(host(session));

    expect(find.bySemanticsLabel('Playback 10 level'), findsOneWidget);

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

  testWidgets('tapping a strip opens its cue picker, tapping a cue jumps to it', (tester) async {
    phone(tester);
    final session = DemoSession();
    await tester.pumpWidget(host(session));

    await tester.tap(find.text('Movers'));
    await tester.pump();
    expect(find.text('Reading the cue list…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Cue Stack - Movers'), findsOneWidget);

    await tester.tap(find.text('Q3.5'));
    await tester.pump();
    expect(session.playbackCue[2], '3.5');
    // The picker closes.
    expect(find.text('Cue Stack - Movers'), findsNothing);

    // Opening it again shows the cached list at once while it refreshes.
    await tester.tap(find.text('Movers'));
    await tester.pump();
    expect(find.text('Reading the cue list…'), findsNothing);
    expect(find.text('Q4'), findsOneWidget);
    expect(find.textContaining('Refreshing'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Cue Stack - Movers'), findsOneWidget);
  });

  test('E labels name the playback buttons', () {
    expect(PlaybackStrip.buttonLabel('E1 Blackout', 1), 'Blackout');
    expect(PlaybackStrip.buttonLabel('E11 Hold', 11), 'Hold');
    expect(PlaybackStrip.buttonLabel('E11 Hold', 1), isNull);
    expect(PlaybackStrip.buttonLabel('E1', 1), isNull);
    expect(PlaybackStrip.buttonLabel('Front wash', 1), isNull);
    expect(PlaybackStrip.buttonLabel(null, 1), isNull);
  });

  test('speed master multipliers read as rates', () {
    expect(PlaybackStrip.rate('x2'), '2x');
    expect(PlaybackStrip.rate('/2'), '1/2x');
    expect(PlaybackStrip.rate(null), isNull);
  });

  testWidgets('E labels replace Go and Pause and hide their lines', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = DemoSession();
    session.playbackCueName[1] = 'E2 Next song';
    session.playbackNextCue[1] = 'E12 Hold';
    await tester.pumpWidget(host(session));

    expect(find.text('Next song'), findsOneWidget);
    expect(find.text('Hold'), findsOneWidget);
    expect(find.text('E2 Next song'), findsNothing);
    expect(find.text('› E12 Hold'), findsNothing);
    expect(find.text('Back light'), findsOneWidget);
  });

  testWidgets('exit only disconnects after a full hold', (tester) async {
    phone(tester);
    var disconnected = 0;
    await tester.pumpWidget(host(DemoSession(), onDisconnect: () => disconnected++));

    final exit = tester.getCenter(find.text('Exit'));
    var gesture = await tester.startGesture(exit);
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(disconnected, 0);

    gesture = await tester.startGesture(exit);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await gesture.up();
    expect(disconnected, 1);
  });

  testWidgets('top bar toggles hide Go/Pause and Flash', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(DemoSession()));
    expect(find.byType(TransportIcon), findsWidgets);
    expect(find.text('Go'), findsNothing); // icons, not text
    expect(find.text('Flash'), findsNWidgets(playbackCount + 1));

    await tester.tap(find.text('Go/Pause'));
    await tester.pump();
    expect(find.byType(TransportIcon), findsNothing);

    await tester.tap(find.text('Flash').first);
    await tester.pump();
    expect(find.text('Flash'), findsOneWidget); // the toggle itself
  });

  testWidgets('split view shows playbacks and the Execute grid', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(DemoSession()));
    await tester.tap(find.text('Split'));
    await tester.pump();
    expect(find.text('Pg 1'), findsOneWidget);
    expect(find.text('Warm wash'), findsOneWidget);
    expect(find.text('Main'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page steppers fit in the top bar on a small phone', (tester) async {
    phone(tester, const Size(667, 375));
    await tester.pumpWidget(host(DemoSession()));
    final barBottom = tester.getBottomLeft(find.text('Split')).dy;
    for (final view in ['Playbacks', 'Execute', 'Split']) {
      await tester.tap(find.text(view));
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final arrow in find.text('›').evaluate()) {
        expect(tester.getCenter(find.byWidget(arrow.widget)).dy, lessThan(barBottom));
      }
    }
    expect(find.text('›'), findsNWidgets(2));
  });

  testWidgets('execute flash items are on only while held, sized items span cells', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = DemoSession();
    await tester.pumpWidget(host(session));
    await tester.tap(find.text('Execute'));
    await tester.pump();

    final gesture = await tester.startGesture(tester.getCenter(find.text('Strobe hit')));
    await tester.pump();
    expect(session.executePage!.items.firstWhere((i) => i.name == 'Strobe hit').active, isTrue);
    await gesture.up();
    await tester.pump();
    expect(session.executePage!.items.firstWhere((i) => i.name == 'Strobe hit').active, isFalse);

    final hit = tester.getSize(find.ancestor(of: find.text('Strobe hit'), matching: find.byType(Positioned)).first);
    final blackout = tester.getSize(find.ancestor(of: find.text('All off'), matching: find.byType(Positioned)).first);
    expect(blackout.width, closeTo(hit.width * 2, 0.5));
  });

  testWidgets('execute cells drop the type tag when the name needs the room', (tester) async {
    phone(tester);
    ExecutePage page(String name) => ExecutePage(
      page: 1,
      name: '',
      columns: 1,
      rows: 1,
      flags: 0,
      items: [ExecuteItem(index: 0, flags: 1, name: name, tag: 'CS')],
    );
    Future<void> show(String name, Size size) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox.fromSize(
            size: size,
            child: ExecuteGrid(session: DemoSession(), page: page(name)),
          ),
        ),
      ),
    );

    await show('Wash', const Size(80, 70));
    expect(find.text('CS'), findsOneWidget);
    await show('Wash', const Size(80, 40));
    expect(find.text('CS'), findsNothing);
    await show('Very long cue stack name', const Size(80, 70));
    expect(find.text('CS'), findsNothing);
    expect(find.text('Very long cue stack name'), findsOneWidget);
  });

  testWidgets('the split divider drags left and right', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(DemoSession()));
    await tester.tap(find.text('Split'));
    await tester.pump();

    final divider = find.bySemanticsLabel('Split divider');
    final start = tester.getCenter(divider).dx;
    await tester.drag(divider, const Offset(-150, 0));
    await tester.pump();
    expect(tester.getCenter(divider).dx, closeTo(start - 150, 20));

    // Each pane keeps a minimum width.
    await tester.drag(divider, const Offset(-2000, 0));
    await tester.pump();
    expect(tester.getCenter(divider).dx, greaterThan(100));
    expect(tester.takeException(), isNull);
  });
}
