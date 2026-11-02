import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../catalog/jurisdictions.dart';
import '../catalog/permissions.dart';
import '../client.dart';
import '../core/age_gate.dart';
import '../core/ask_watcher.dart';
import '../core/session_store.dart';
import '../core/settings.dart';
import '../core/types.dart';
import '../core/verify_age.dart';
import '../errors.dart';
import '../jurisdiction_option.dart';
import '../log.dart';
import '../models.dart';
import '../platform/platform.dart';
import '../localization.dart';
import '../strings.dart';
import 'appearance.dart';
import 'jurisdictions.dart';

/// Builds the provider's client; tests replace it to script k-ID's answers.
@visibleForTesting
Client Function(ClientOptions options) createClient = FapiClient.new;

const _maxDeclareAttempts = 4;

Duration _declareRetryDelay(int attempt) => Duration(milliseconds: (250 << (attempt - 1)).clamp(0, 2000));

// `unavailable` covers both transport failures and the config-not-served-yet signal declare returns while a written
// config propagates; a definitive failure (bad key or permission) is not retried.
bool _isRetryableDeclareError(Object e) =>
    e is KidError && (e.code == KidErrorCode.unavailable || e.code == KidErrorCode.rateLimited);

enum _DeclarationStatus { ready, pending, error }

/// What [KidCoreProvider] holds for the widgets below it.
class KidCoreContext extends ChangeNotifier {
  KidCoreContext._(this._client, this._appearance, KidLocalization? localization) {
    _asks = AskWatcher(client: _client, sessions: _sessions)..start();
    _localize(localization);
  }

  final Client _client;
  final _sessions = SessionStore();
  late final AskWatcher _asks;

  /// The widgets' look.
  KidAppearance get appearance => _appearance;
  KidAppearance _appearance;

  void _setAppearance(KidAppearance appearance) {
    _appearance = appearance;
    notifyListeners();
  }

  /// The copy the widgets render: the English defaults with the provider's localization merged over them.
  KidStrings get strings => _strings;
  late KidStrings _strings;

  String? _locale;

  /// Right to left for an Arabic locale; null without a locale, which keeps the app's direction.
  @internal
  TextDirection? get direction => switch (isRightToLeft(_locale)) {
        true => TextDirection.rtl,
        false => TextDirection.ltr,
        null => null,
      };

  void _relocalize(KidLocalization? localization) {
    _localize(localization);
    notifyListeners();
  }

  void _localize(KidLocalization? localization) {
    _strings = mergeStrings(localization);
    _locale = localization?.locale;
    _jurisdictions = localizeJurisdictions(_strings);
    _nameCountries(_locale);
  }

  /// The jurisdiction picker's options, for a custom picker.
  List<JurisdictionOption> get jurisdictions => _jurisdictions;
  late List<JurisdictionOption> _jurisdictions;

  // Names the countries in [locale] once the platform has them; English until then, and for English.
  void _nameCountries(String? locale) {
    if (locale == null || locale.split(RegExp('[-_]')).first.toLowerCase() == 'en') return;
    unawaited(countryNames(locale, [for (final c in countries) c.code]).then((names) {
      if (_disposed || names.isEmpty || locale != _locale) return;
      _jurisdictions = localizeJurisdictions(_strings, localNames: names);
      notifyListeners();
    }));
  }

  _DeclarationStatus _declaration = _DeclarationStatus.ready;
  Object? _declarationError;
  bool _disposed = false;

  void _declare(KidDeclare declare) {
    _declaration = _DeclarationStatus.pending;
    unawaited(() async {
      // Declare is idempotent server-side, so retrying a transient failure is safe.
      for (var attempt = 1;; attempt++) {
        try {
          await _client.declare(declare);
          _declaration = _DeclarationStatus.ready;
          break;
        } catch (e) {
          if (attempt >= _maxDeclareAttempts || !_isRetryableDeclareError(e)) {
            KidLog.error('declare failed', e);
            _declarationError = e;
            _declaration = _DeclarationStatus.error;
            break;
          }
          await Future<void>.delayed(_declareRetryDelay(attempt));
        }
      }
      if (!_disposed) notifyListeners();
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    _asks.stop();
    super.dispose();
  }
}

class _KidCoreScope extends InheritedNotifier<KidCoreContext> {
  const _KidCoreScope({required KidCoreContext context, required super.child}) : super(notifier: context);
}

/// The app-level k-ID provider; wrap your app once.
class KidCoreProvider extends StatefulWidget {
  const KidCoreProvider({
    super.key,
    required this.publishableKey,
    required this.baseUrl,
    this.declare,
    this.appearance = const KidAppearance(),
    this.localization,
    required this.child,
  });

  /// Your k-ID publishable key; safe to ship in the app.
  final String publishableKey;

  /// The k-ID API URL Kai shows for your key: `https://kai-api.k-id.com/fapi/v1` for a live key,
  /// `https://kai-api.test.k-id.com/fapi/v1` for a test key.
  final String baseUrl;

  /// The integration manifest, read once and applied only while you use a test key.
  final KidDeclare? declare;
  final KidAppearance appearance;

  /// A locale, such as [KidLocalization.jaJP] or one from [getKidLocalization], or your own wording, merged over the
  /// English defaults. Locale detection stays in your app.
  final KidLocalization? localization;
  final Widget child;

  static KidCoreContext of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_KidCoreScope>();
    if (scope == null) throw FlutterError('Place this inside a KidCoreProvider.');
    return scope.notifier!;
  }

  @override
  State<KidCoreProvider> createState() => _KidCoreProviderState();
}

class _KidCoreProviderState extends State<KidCoreProvider> {
  late final KidCoreContext _context;

  @override
  void initState() {
    super.initState();
    final client = createClient(platformClientOptions(publishableKey: widget.publishableKey, baseUrl: widget.baseUrl));
    _context = KidCoreContext._(client, widget.appearance, widget.localization);
    final declare = widget.declare;
    // A live key's declare is a server no-op, so a live launch skips the round trip.
    if (declare != null && !widget.publishableKey.startsWith('kgp_live_')) _context._declare(declare);
  }

  @override
  void didUpdateWidget(KidCoreProvider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.appearance != oldWidget.appearance) _context._setAppearance(widget.appearance);
    if (widget.localization != oldWidget.localization) _context._relocalize(widget.localization);
  }

  @override
  void dispose() {
    _context.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _KidCoreScope(context: _context, child: widget.child);
}

/// The age gate's status, ids, requirements and `submit`.
class UseKidAgeGate {
  const UseKidAgeGate._(this._state, this.submit);

  final AgeGateState _state;

  KidStatus get status => _state.status;
  String? get challengeId => _state.challengeId;

  /// `parentalConsent` when the email goes to a parent, `ageAssurance` when it goes to the player, null before there is
  /// a challenge.
  ChallengeKind? get challengeKind => _state.challengeKind;
  String? get sessionId => _state.sessionId;

  /// The error behind `error`: a k-ID API error as is, and any other failure as `unavailable`.
  KidError? get error => _state.error;

  /// The jurisdiction's requirements, including its digital consent, civil, minimum and access ages.
  Requirements? get requirements => _state.requirements;

  /// Sends the challenge email once the check has produced a challenge; call it again to re-send.
  final Future<KidResult> Function() submit;
}

/// Verifies the player is an adult on the established session; the headless form of `KidSessionVerifyAge`.
class UseKidSessionVerifyAge {
  const UseKidSessionVerifyAge._(this._state, this._controller);

  static const _beforeSession = VerifyAgeState(
    status: KidStatus.running,
    step: null,
    challengeId: null,
    rawChallengeStatus: null,
    expiresAt: null,
    error: null,
  );

  final VerifyAgeState _state;
  final VerifyAgeController? _controller;

  KidStatus get status => _state.status;
  VerifyAgeStep? get step => _state.step;
  String? get challengeId => _state.challengeId;
  RawChallengeStatus? get rawChallengeStatus => _state.rawChallengeStatus;
  String? get expiresAt => _state.expiresAt;
  KidError? get error => _state.error;

  /// Checks the session: a no-op until the gate passes; after a fail or error it starts over with a fresh check.
  void start() => _controller?.start();

  /// Sends the player the verification link; call it again to re-send to a corrected address.
  Future<KidResult> submit(String email) {
    final controller = _controller;
    if (controller == null) return Future.value(KidResult.failed(localKidError()));
    controller.setEmail(email);
    return controller.submit();
  }
}

/// The established session, its permissions and its age verification.
class UseKidSession {
  const UseKidSession._(this._state, this.verifyAge, this.refresh);

  final AgeGateState _state;

  Session? get session => _state.session;

  /// Each permission's name to whether it is enabled.
  Map<PermissionName, bool> get permissions => {
        for (final p in _state.session?.permissions ?? const <Permission>[]) p.permissionName: p.enabled,
      };
  String? get sessionId => _state.sessionId;
  bool get isLoaded => _state.session != null;

  /// Set once the player has proven an age. The player is a verified adult when `verifiedAge` is at least the
  /// requirements' `civilAge`.
  AgeVerification? get ageVerification => _state.session?.ageVerification;
  final UseKidSessionVerifyAge verifyAge;

  /// Re-reads the session; an unchanged one is a cheap 304.
  final Future<void> Function() refresh;
}

/// `can` and `get` for the session's permissions. They gate what a player sees; enforce the real capability
/// server-side.
class UseKidPermission {
  UseKidPermission._(List<Permission> permissions) : _byName = {for (final p in permissions) p.name: p};

  final Map<String, Permission> _byName;

  bool can(PermissionName name) => _byName[name.value]?.enabled ?? false;

  /// The full permission including `managedBy`, so you can explain a guardian-managed feature rather than hide it.
  Permission? get(PermissionName name) => _byName[name.value];
}

/// The raw challenge status, for a custom waiting screen.
class UseKidChallenge {
  const UseKidChallenge._(this.challengeId, this.status, this.expiresAt);

  final String? challengeId;
  final RawChallengeStatus? status;

  /// Set only when the challenge has a deadline; once it passes, the flow moves to `fail`.
  final String? expiresAt;
}

/// What [KidSessionProvider] holds: the age gate, read and driven headlessly.
class KidAgeGateController extends ChangeNotifier {
  KidAgeGateController._(this._gate) {
    _unsubscribe = _gate.subscribe(_changed);
  }

  final AgeGateController _gate;
  late final void Function() _unsubscribe;
  VerifyAgeController? _verifyAge;
  void Function()? _unsubscribeVerifyAge;

  @internal
  AgeGateController get gate => _gate;

  void _changed() {
    final verifyAge = _gate.sessionVerifyAge;
    if (!identical(verifyAge, _verifyAge)) {
      _unsubscribeVerifyAge?.call();
      _verifyAge = verifyAge;
      _unsubscribeVerifyAge = verifyAge?.subscribe(notifyListeners);
    }
    notifyListeners();
  }

  UseKidAgeGate get ageGate => UseKidAgeGate._(_gate.state, _gate.submit);

  UseKidSession get session {
    final verifyAge = _gate.sessionVerifyAge;
    return UseKidSession._(
      _gate.state,
      UseKidSessionVerifyAge._(verifyAge?.state ?? UseKidSessionVerifyAge._beforeSession, verifyAge),
      _gate.refreshSession,
    );
  }

  UseKidPermission get permission => UseKidPermission._(_gate.state.session?.permissions ?? const []);

  UseKidChallenge get challenge =>
      UseKidChallenge._(_gate.state.challengeId, _gate.state.rawChallengeStatus, _gate.state.expiresAt);

  @override
  void dispose() {
    _unsubscribe();
    _unsubscribeVerifyAge?.call();
    super.dispose();
  }
}

class _KidSessionScope extends InheritedNotifier<KidAgeGateController> {
  const _KidSessionScope({required KidAgeGateController controller, required super.child})
      : super(notifier: controller);
}

/// Wraps one age gate. Omit [jurisdiction] to show the picker, [age] to show the age step, [email] to show the email
/// form. The SDK stores nothing: keep the ids from [onChallenge] and [onSession] and pass them back to resume.
/// Recreate the provider (for example with a new key) to start over.
class KidSessionProvider extends StatefulWidget {
  const KidSessionProvider({
    super.key,
    this.jurisdiction,
    this.age,
    this.email,
    this.challengeId,
    this.sessionId,
    this.onChallenge,
    this.onSession,
    this.onClaim,
    required this.child,
  });

  /// A country or subdivision code, or [JurisdictionCode.auto] to resolve it from the client IP (falling back to the
  /// picker). Age and jurisdiction freeze once the check runs; later changes are ignored with a warning.
  final JurisdictionCode? jurisdiction;
  final AgeSignal? age;

  /// The grownup's email for consent, or the player's own email for adult age verification.
  final String? email;
  final String? challengeId;
  final String? sessionId;

  /// Fires once a challenge's email is sent; keep the id to resume.
  final ValueChanged<String>? onChallenge;

  /// Fires once the session is established; keep the id to resume.
  final ValueChanged<String>? onSession;

  /// Fires once the age check has a result, passed or pending, with a one-time token for your backend. Not fired on
  /// resume or when the player is prohibited.
  final ValueChanged<String>? onClaim;
  final Widget child;

  static KidAgeGateController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_KidSessionScope>();
    if (scope == null) throw FlutterError('Place this inside a KidSessionProvider.');
    return scope.notifier!;
  }

  @override
  State<KidSessionProvider> createState() => _KidSessionProviderState();
}

class _KidSessionProviderState extends State<KidSessionProvider> {
  KidAgeGateController? _controller;
  String? _firedChallenge;
  String? _firedSession;
  String? _firedClaim;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final core = KidCoreProvider.of(context);
    final controller = _controller ??= KidAgeGateController._(AgeGateController(
      client: core._client,
      sessions: core._sessions,
      jurisdiction: widget.jurisdiction?.value,
      age: widget.age,
      email: widget.email,
      challengeId: widget.challengeId,
      sessionId: widget.sessionId,
    ))
      ..addListener(_report);
    // The flow reads the test config declare writes, so it holds its requests until declare lands.
    switch (core._declaration) {
      case _DeclarationStatus.ready:
        controller.gate.start();
      case _DeclarationStatus.error:
        controller.gate.declarationFailed(core._declarationError);
      case _DeclarationStatus.pending:
        break;
    }
  }

  @override
  void didUpdateWidget(KidSessionProvider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.jurisdiction != oldWidget.jurisdiction ||
        widget.age != oldWidget.age ||
        widget.email != oldWidget.email) {
      _controller?.gate.configure(jurisdiction: widget.jurisdiction?.value, age: widget.age, email: widget.email);
    }
  }

  void _report() {
    final state = _controller!.gate.state;
    final challengeId = resumableChallengeId(state);
    if (challengeId != null && challengeId != _firedChallenge) {
      _firedChallenge = challengeId;
      widget.onChallenge?.call(challengeId);
    }
    final sessionId = state.sessionId;
    if (sessionId != null && sessionId != _firedSession) {
      _firedSession = sessionId;
      widget.onSession?.call(sessionId);
    }
    final claimToken = state.claimToken;
    if (claimToken != null && claimToken != _firedClaim) {
      _firedClaim = claimToken;
      widget.onClaim?.call(claimToken);
    }
  }

  @override
  void dispose() {
    _controller?.gate.destroy();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _KidSessionScope(controller: _controller!, child: widget.child);
  }
}

/// The settings menu's permissions, `change`, `upgrade` and the in-flight ask.
class UseKidPermissionSettings {
  const UseKidPermissionSettings._(this._state, this._controller);

  final SettingsState _state;
  final SettingsController _controller;

  /// Every permission on the session, with its `managedBy`, so a custom UI can branch per row.
  List<Permission> get permissions => _state.session?.permissions ?? const [];
  bool get isLoaded => _state.isLoaded;

  /// Why the session failed to load, or null; show an error and call [refresh] to retry.
  KidError? get error => _state.error;

  /// Whether the session has an approver email. When false, collect one and pass it to [upgrade].
  bool get hasApproverEmail => _state.session?.hasApproverEmail != false;

  /// The in-flight ask, for a custom waiting view.
  SettingsChallengeState get challenge => _state.challenge;

  /// Turns a player-managed permission on or off. Guardian-managed and prohibited ones are rejected.
  Future<KidResult> change(PermissionName name, bool enabled) => _controller.change(name, enabled);

  /// Asks for permissions in one request. A guardian-managed set is emailed to the grownup ([approverEmail] when
  /// [hasApproverEmail] is false). A player-managed permission with a `verifiedAgeThreshold` is asked for on its own:
  /// without an email this returns `invalidRequest` when an age check is needed; call it again with the player's own
  /// email. One call can't mix permissions with a `verifiedAgeThreshold` and ones without.
  Future<KidResult> upgrade(List<PermissionName> names, {String? approverEmail}) =>
      _controller.upgrade(names, approverEmail);

  Future<void> refresh() => _controller.refresh();
}

/// What [KidSettingsProvider] holds: the settings menu, read and driven headlessly.
class KidSettingsController extends ChangeNotifier {
  KidSettingsController._(this._settings) {
    _unsubscribe = _settings.subscribe(notifyListeners);
  }

  final SettingsController _settings;
  late final void Function() _unsubscribe;

  @internal
  SettingsController get settings => _settings;

  UseKidPermissionSettings get permissionSettings => UseKidPermissionSettings._(_settings.state, _settings);

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }
}

class _KidSettingsScope extends InheritedNotifier<KidSettingsController> {
  const _KidSettingsScope({required KidSettingsController controller, required super.child})
      : super(notifier: controller);
}

/// Wraps the settings menu for [sessionId], the session from the age gate's `onSession`. [onChallenge] gets the
/// settings challenge id once its email is sent; pass it back as [challengeId] to resume.
class KidSettingsProvider extends StatefulWidget {
  const KidSettingsProvider({
    super.key,
    required this.sessionId,
    this.challengeId,
    this.onChallenge,
    required this.child,
  });

  final String sessionId;
  final String? challengeId;
  final ValueChanged<String>? onChallenge;
  final Widget child;

  static KidSettingsController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_KidSettingsScope>();
    if (scope == null) throw FlutterError('Place this inside a KidSettingsProvider.');
    return scope.notifier!;
  }

  @override
  State<KidSettingsProvider> createState() => _KidSettingsProviderState();
}

class _KidSettingsProviderState extends State<KidSettingsProvider> {
  KidSettingsController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final core = KidCoreProvider.of(context);
    _controller = KidSettingsController._(SettingsController(
      client: core._client,
      sessionId: widget.sessionId,
      challengeId: widget.challengeId,
      onChallenge: (id) => widget.onChallenge?.call(id),
      sessions: core._sessions,
      asks: core._asks,
    ))
      ..settings.start();
  }

  @override
  void dispose() {
    _controller?.settings.destroy();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _KidSettingsScope(controller: _controller!, child: widget.child);
}
