import 'package:flutter/widgets.dart';
import 'package:magicq_remote/magicq_remote.dart';

import '../session.dart';
import '../theme.dart';
import '../widgets/console_button.dart';
import '../widgets/text_input.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    super.key,
    required this.onSession,
    this.initialHost = '',
  });

  final ValueChanged<ConsoleSession> onSession;
  final String initialHost;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final _host = TextEditingController(text: widget.initialHost);
  final _user = TextEditingController();
  final _password = TextEditingController();
  List<ConsoleInfo> _found = const [];
  bool _scanning = false;
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    List<ConsoleInfo> found = const [];
    try {
      found = await discoverConsoles();
    } catch (_) {
      // Discovery is best effort (e.g. broadcast blocked); typing an
      // address still works.
    }
    if (!mounted) return;
    setState(() {
      _found = found;
      _scanning = false;
    });
  }

  Future<void> _connect(String host) async {
    if (host.trim().isEmpty) {
      setState(() => _error = 'Enter the console IP address.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final client = await MagicQClient.connect(
        host.trim(),
        user: _user.text.trim().isEmpty ? null : _user.text.trim(),
        password: _password.text,
      );
      widget.onSession(LiveSession(client));
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e is MagicQConnectException
            ? e.message
            : 'Could not connect: $e',
      );
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Palette.chassis,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Lighting Station', style: TextStyles.title),
                  const SizedBox(height: 4),
                  Text(
                    'Connect to a MagicQ console on this network.',
                    style: TextStyles.body.copyWith(color: Palette.textDim),
                  ),
                  const SizedBox(height: 24),
                  _section(
                    'Consoles found',
                    trailing: _scanning ? 'Scanning…' : null,
                  ),
                  if (_found.isEmpty && !_scanning)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'None found. Enter the address below.',
                        style: TextStyles.small,
                      ),
                    ),
                  for (final c in _found) ...[
                    _ConsoleRow(
                      info: c,
                      onTap: _connecting ? null : () => _connect(c.address),
                    ),
                    const SizedBox(height: 4),
                  ],
                  const SizedBox(height: 4),
                  ConsoleButton(
                    label: 'Scan again',
                    height: 36,
                    onDown: _scanning ? null : _scan,
                  ),
                  const SizedBox(height: 24),
                  _section('Address'),
                  Localizations.override(
                    context: context,
                    locale: const Locale('en', 'US'),
                    child: TextInput(
                      controller: _host,
                      placeholder: '192.168.1.10',
                      onSubmitted: _connect,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextInput(
                          controller: _user,
                          placeholder: 'User (if set up)',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextInput(
                          controller: _password,
                          placeholder: 'Password',
                          obscure: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ConsoleButton(
                    label: _connecting ? 'Connecting…' : 'Connect',
                    height: 48,
                    lit: true,
                    onDown: _connecting ? null : () => _connect(_host.text),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyles.body.copyWith(color: Palette.flash),
                    ),
                  ],
                  const SizedBox(height: 28),
                  Text(
                    'In MagicQ Setup, turn on "Enable remote app". Playback faders '
                    'also need "Ethernet remote protocol" set to "ChamSys Rem (tx + rx)".',
                    style: TextStyles.small,
                  ),
                  const SizedBox(height: 16),
                  ConsoleButton(
                    label: 'Try without a console',
                    height: 36,
                    onDown: () => widget.onSession(DemoSession()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(String title, {String? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Text(title, style: TextStyles.label.copyWith(color: Palette.textDim)),
        const Spacer(),
        if (trailing != null) Text(trailing, style: TextStyles.small),
      ],
    ),
  );
}

class _ConsoleRow extends StatelessWidget {
  const _ConsoleRow({required this.info, required this.onTap});

  final ConsoleInfo info;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Palette.raised,
          border: const Border(
            left: BorderSide(color: Palette.online, width: 3),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.displayName,
                    style: TextStyles.label.copyWith(fontSize: 14),
                  ),
                  Text(
                    '${info.address}, MagicQ ${info.version}',
                    style: TextStyles.small,
                  ),
                ],
              ),
            ),
            Text(
              'Connect',
              style: TextStyles.label.copyWith(color: Palette.live),
            ),
          ],
        ),
      ),
    );
  }
}
