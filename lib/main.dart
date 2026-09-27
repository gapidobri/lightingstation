import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'screens/connect_screen.dart';
import 'screens/console_screen.dart';
import 'session.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const LightingStationApp());
}

class LightingStationApp extends StatelessWidget {
  const LightingStationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      title: 'Lighting Station',
      color: Palette.chassis,
      debugShowCheckedModeBanner: false,
      textStyle: TextStyles.body,
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(settings: settings, pageBuilder: (context, _, _) => builder(context)),
      home: const _Root(),
    );
  }
}

/// Shows the connect screen until a session exists, then the console.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  // `--dart-define=DEMO=true` starts in the offline demo, for UI work.
  ConsoleSession? _session = const bool.fromEnvironment('DEMO') ? DemoSession() : null;
  String _lastHost = '';

  void _open(ConsoleSession session) {
    if (session is LiveSession) _lastHost = session.client.console.address;
    setState(() => _session = session);
  }

  void _close() {
    _session?.dispose();
    setState(() => _session = null);
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return session == null
        ? ConnectScreen(onSession: _open, initialHost: _lastHost)
        : ConsoleScreen(session: session, onDisconnect: _close);
  }
}
