import 'package:flutter/material.dart';
import 'package:k_id_core/k_id_core.dart';

// Run with your test key, for example:
// flutter run --dart-define=KID_PUBLISHABLE_KEY=kgp_test_...
const publishableKey = String.fromEnvironment('KID_PUBLISHABLE_KEY');
const baseUrl = String.fromEnvironment('KID_BASE_URL', defaultValue: 'https://kai-api.test.k-id.com/fapi/v1');

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'k-ID example',
        home: KidCoreProvider(
          publishableKey: publishableKey,
          baseUrl: baseUrl,
          declare: const KidDeclare(
            permissions: [PermissionName.textChatPublic, PermissionName.voiceChat],
            supportEmail: 'help@example.com',
          ),
          child: const Home(),
        ),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  // The SDK stores nothing; an app keeps these to resume after a restart.
  String? _sessionId;
  String? _challengeId;
  int _attempt = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('k-ID example')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: KidSessionProvider(
            key: ValueKey(_attempt),
            jurisdiction: JurisdictionCode.auto,
            challengeId: _challengeId,
            onChallenge: (id) => _challengeId = id,
            onSession: (id) => setState(() => _sessionId = id),
            child: KidAgeGate(
              pending: const Text('Waiting for your grownup to approve.'),
              prohibited: const Text('You are too young to play.'),
              fail: _retry('Your grownup said no, or the request expired.'),
              error: Builder(
                builder: (context) =>
                    _retry('Something went wrong: ${KidSessionProvider.of(context).ageGate.error?.message}'),
              ),
              pass: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('You are in.'),
                  const SizedBox(height: 16),
                  const KidPermission(
                    name: PermissionName.voiceChat,
                    fallback: Text('Voice chat is off.'),
                    child: Text('Voice chat is on.'),
                  ),
                  const SizedBox(height: 16),
                  if (_sessionId != null) KidSettingsProvider(sessionId: _sessionId!, child: const KidSettings()),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _retry(String message) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(message),
          TextButton(
            onPressed: () => setState(() {
              _attempt++;
              _challengeId = null;
            }),
            child: const Text('Start over'),
          ),
        ],
      );
}
