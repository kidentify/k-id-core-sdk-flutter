part of 'components.dart';

enum _VerifyAgeStep { verify, email, sending }

String _rowName(KidStrings strings, Permission permission) => format(
      strings.settings.enabledLabel,
      {'permission': strings.permissions[permission.name]?.name ?? permission.name},
    );

class _Row extends StatelessWidget {
  const _Row({required this.name, required this.trailing});

  final String name;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final appearance = KidCoreProvider.of(context).appearance;
    return KidElement(
      appearance: appearance,
      keys: const [KidElementName.row],
      child: Row(children: [
        Expanded(child: _Text(KidElementName.label, name)),
        const SizedBox(width: 12),
        trailing,
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.semantics, required this.added, required this.onTap});

  final String label;
  final String semantics;
  final bool added;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final appearance = KidCoreProvider.of(context).appearance;
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: KidElement(
          appearance: appearance,
          keys: [KidElementName.pill, added ? KidElementName.pillAdded : KidElementName.pillAsk],
          child: Text(label),
        ),
      ),
    );
  }
}

class _PlayerRow extends StatefulWidget {
  const _PlayerRow({required this.permission});

  final Permission permission;

  @override
  State<_PlayerRow> createState() => _PlayerRowState();
}

class _PlayerRowState extends State<_PlayerRow> {
  bool _busy = false;
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final core = KidCoreProvider.of(context);
    final settings = KidSettingsProvider.of(context).permissionSettings;
    final t = core.strings.settings;
    final p = widget.permission;
    final name = _rowName(core.strings, p);
    return _Row(
      name: name,
      trailing: KidElement(
        appearance: core.appearance,
        keys: const [KidElementName.controlColumn],
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            _Text(KidElementName.muted, p.enabled ? t.on : t.off),
            const SizedBox(width: 8),
            Switch(
              value: p.enabled,
              activeTrackColor: core.appearance.variables.colorPrimary,
              onChanged: _busy
                  ? null
                  : (enabled) async {
                      setState(() => _busy = true);
                      final res = await settings.change(p.permissionName, enabled);
                      if (mounted) {
                        setState(() {
                          _busy = false;
                          _failed = !res.ok;
                        });
                      }
                    },
            ),
          ]),
          if (_failed) _Text(KidElementName.danger, t.error),
        ]),
      ),
    );
  }
}

class _VerifyAgeRow extends StatefulWidget {
  const _VerifyAgeRow({required this.permission, required this.disabled});

  final Permission permission;
  final bool disabled;

  @override
  State<_VerifyAgeRow> createState() => _VerifyAgeRowState();
}

class _VerifyAgeRowState extends State<_VerifyAgeRow> {
  _VerifyAgeStep _step = _VerifyAgeStep.verify;
  KidErrorCode? _failedCode;
  String _email = '';

  // A failure puts the row back to its button with the error, so the player starts over; without an email,
  // `invalidRequest` is the age check asking for the player's email instead.
  Future<KidResult> _request(UseKidPermissionSettings settings, String? playerEmail) async {
    setState(() {
      _step = _VerifyAgeStep.sending;
      _failedCode = null;
    });
    final res = await settings.upgrade([widget.permission.permissionName], approverEmail: playerEmail);
    if (!mounted) return res;
    setState(() {
      final code = res.error?.code ?? KidErrorCode.unavailable;
      if (res.ok) {
        _step = _VerifyAgeStep.verify;
      } else if (playerEmail == null && code == KidErrorCode.invalidRequest) {
        _step = _VerifyAgeStep.email;
      } else {
        _step = _VerifyAgeStep.verify;
        _failedCode = code;
      }
    });
    return res;
  }

  @override
  Widget build(BuildContext context) {
    final core = KidCoreProvider.of(context);
    final settings = KidSettingsProvider.of(context).permissionSettings;
    final strings = core.strings;
    final p = widget.permission;
    final name = _rowName(strings, p);
    final challenge = settings.challenge;
    final mine =
        challenge.challengeKind == ChallengeKind.ageAssurance && challenge.permissions.contains(p.permissionName);
    if (_step == _VerifyAgeStep.sending || (mine && challenge.status == SettingsChallengeStatus.pending)) {
      return _Row(
        name: name,
        trailing: _Text(
          KidElementName.muted,
          _step == _VerifyAgeStep.sending ? strings.verifyAge.submitting : strings.settings.verifying,
        ),
      );
    }
    if (_step == _VerifyAgeStep.email) {
      return _ChallengeEmailForm(
        strings: (s) => s.verifyAge,
        element: KidElementName.verifyAge,
        setEmail: (email) => _email = email,
        send: () => _request(settings, _email),
      );
    }
    final failed = _failedCode;
    final label = strings.verifyAge.title;
    return _Row(
      name: name,
      trailing: KidElement(
        appearance: core.appearance,
        keys: const [KidElementName.controlColumn],
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          _Pill(
            label: label,
            semantics: '$label $name',
            added: false,
            onTap: widget.disabled ? null : () => _request(settings, null),
          ),
          if (failed != null)
            _Text(
              KidElementName.danger,
              failed == KidErrorCode.invalidRequest ? strings.verifyAge.invalidEmail : strings.verifyAge.error,
            ),
        ]),
      ),
    );
  }
}

class _GuardianRow extends StatelessWidget {
  const _GuardianRow({required this.permission, required this.added, required this.disabled, required this.onToggle});

  final Permission permission;
  final bool added;
  final bool disabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final strings = KidCoreProvider.of(context).strings;
    final t = strings.settings;
    final name = _rowName(strings, permission);
    if (permission.enabled) return _Row(name: name, trailing: _Text(KidElementName.muted, t.granted));
    final label = added ? t.added : t.ask;
    return _Row(
      name: name,
      trailing: _Pill(label: label, semantics: '$label $name', added: added, onTap: disabled ? null : onToggle),
    );
  }
}

/// The permission menu without its surrounding card, for your own settings screen.
class KidPermissionSettings extends StatefulWidget {
  const KidPermissionSettings({super.key});

  @override
  State<KidPermissionSettings> createState() => _KidPermissionSettingsState();
}

class _KidPermissionSettingsState extends State<KidPermissionSettings> {
  List<PermissionName> _staged = [];
  final _approverEmail = TextEditingController();
  KidErrorCode? _failedCode;
  // The ask this form sent itself, so a verify-age row's request never shows here.
  bool _asking = false;
  bool _askFailed = false;
  SettingsChallengeState? _lastChallenge;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final challenge = KidSettingsProvider.of(context).permissionSettings.challenge;
    // A parental-consent ask the watcher saw fail is staged again.
    if (challenge != _lastChallenge) {
      _lastChallenge = challenge;
      if (_grownupError(challenge) && _staged.isEmpty) _staged = challenge.permissions;
    }
  }

  @override
  void dispose() {
    _approverEmail.dispose();
    super.dispose();
  }

  bool _grownupError(SettingsChallengeState c) =>
      c.status == SettingsChallengeStatus.error && c.challengeKind == ChallengeKind.parentalConsent;

  Future<void> _ask(UseKidPermissionSettings s) async {
    if (_staged.isEmpty) return;
    final names = _staged;
    setState(() {
      _staged = [];
      _askFailed = false;
      _asking = true;
    });
    final res = await s.upgrade(names, approverEmail: s.hasApproverEmail ? null : _approverEmail.text.trim());
    if (!mounted) return;
    setState(() {
      _asking = false;
      // A failed ask stages the same permissions again, with the error.
      if (!res.ok) _staged = names;
      _failedCode = res.ok ? null : (res.error?.code ?? KidErrorCode.unavailable);
      _askFailed = !res.ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final core = KidCoreProvider.of(context);
    final s = KidSettingsProvider.of(context).permissionSettings;
    final strings = core.strings;
    final t = strings.settings;
    final challenge = s.challenge;
    final inFlight =
        challenge.status == SettingsChallengeStatus.sending || challenge.status == SettingsChallengeStatus.pending;
    final needsEmail = !s.hasApproverEmail && !inFlight;
    final waiting =
        challenge.status == SettingsChallengeStatus.pending && challenge.challengeKind != ChallengeKind.ageAssurance;
    final grownupFailed = _askFailed || _grownupError(challenge);

    if (s.error != null && !s.isLoaded) return _withMaterial(context, _Text(KidElementName.danger, t.error));
    if (!s.isLoaded) return const SizedBox.shrink();
    final rows = <Widget>[
      for (final p in s.permissions)
        if (p.managedBy != ManagedBy.prohibited)
          if (p.managedBy == ManagedBy.guardian)
            _GuardianRow(
              permission: p,
              added: inFlight ? challenge.permissions.contains(p.permissionName) : _staged.contains(p.permissionName),
              disabled: inFlight,
              onToggle: () => setState(() {
                _staged = _staged.contains(p.permissionName)
                    ? [..._staged.where((n) => n != p.permissionName)]
                    : [..._staged, p.permissionName];
              }),
            )
          else if (p.verifiedAgeThreshold != null && !p.enabled)
            _VerifyAgeRow(permission: p, disabled: inFlight || _staged.isNotEmpty)
          else
            _PlayerRow(permission: p),
      if (_staged.isNotEmpty || _asking || waiting)
        KidElement(
          appearance: core.appearance,
          keys: const [KidElementName.askForm],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (needsEmail) ...[
              _Text(KidElementName.label, strings.askAnAdult.title),
              const SizedBox(height: 12),
              _Text(KidElementName.muted, strings.askAnAdult.description),
              const SizedBox(height: 12),
              _Input(
                controller: _approverEmail,
                placeholder: strings.askAnAdult.emailPlaceholder,
                email: true,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
            ],
            _Button(
              label: _asking ? t.asking : (waiting ? t.waiting : t.askGrownup),
              onPressed:
                  !inFlight && !(needsEmail && !_isValidEmail(_approverEmail.text.trim())) ? () => _ask(s) : null,
            ),
          ]),
        ),
      if (grownupFailed)
        Semantics(
          liveRegion: true,
          child: _Text(
            KidElementName.danger,
            s.hasApproverEmail
                ? t.error
                : (_failedCode == KidErrorCode.invalidRequest
                    ? strings.askAnAdult.invalidEmail
                    : strings.askAnAdult.error),
          ),
        ),
    ];
    return _withMaterial(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, row) in rows.indexed) ...[if (i > 0) const SizedBox(height: 12), row],
        ],
      ),
    );
  }
}

/// The all-in-one permission menu: player-managed permissions get an on/off control, guardian-managed ones are staged
/// with a tap and asked for together in one request, and prohibited ones are hidden.
class KidSettings extends StatelessWidget {
  const KidSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final core = KidCoreProvider.of(context);
    return _Card(element: KidElementName.settings, children: [
      _Text(KidElementName.title, core.strings.settings.title),
      const KidPermissionSettings(),
    ]);
  }
}
