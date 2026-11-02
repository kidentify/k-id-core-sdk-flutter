import 'dart:async';

import '../catalog/permissions.dart';
import '../client.dart';
import '../errors.dart';
import '../log.dart';
import '../models.dart';
import 'ask_watcher.dart';
import 'session_store.dart';
import 'timers.dart';
import 'types.dart';

/// The grownup-ask sub-flow: `sending` is minting and emailing; `pending` is waiting on the answer; `error` is the ask
/// failed (it can be asked again).
enum SettingsChallengeStatus { idle, sending, pending, error }

class SettingsChallengeState {
  const SettingsChallengeState({
    required this.status,
    required this.permissions,
    required this.challengeId,
    required this.challengeKind,
  });

  static const idle = SettingsChallengeState(
    status: SettingsChallengeStatus.idle,
    permissions: [],
    challengeId: null,
    challengeKind: null,
  );

  final SettingsChallengeStatus status;

  /// The permissions in the current ask, so a UI can mark those rows as waiting.
  final List<PermissionName> permissions;
  final String? challengeId;

  /// What the challenge asks for: a grownup's approval, or the player's own age check. Null until known.
  final ChallengeKind? challengeKind;

  @override
  bool operator ==(Object other) =>
      other is SettingsChallengeState &&
      other.status == status &&
      other.challengeId == challengeId &&
      other.challengeKind == challengeKind &&
      other.permissions.length == permissions.length &&
      Iterable<int>.generate(permissions.length).every((i) => other.permissions[i] == permissions[i]);

  @override
  int get hashCode => Object.hash(status, challengeId, challengeKind, Object.hashAll(permissions));
}

class SettingsState {
  const SettingsState({required this.session, required this.isLoaded, required this.error, required this.challenge});

  final Session? session;
  final bool isLoaded;

  /// Why the session failed to load: a k-ID API error as is, and any other failure as `unavailable`.
  final KidError? error;
  final SettingsChallengeState challenge;

  SettingsState copyWith({
    Object? session = unset,
    bool? isLoaded,
    Object? error = unset,
    SettingsChallengeState? challenge,
  }) =>
      SettingsState(
        session: identical(session, unset) ? this.session : session as Session?,
        isLoaded: isLoaded ?? this.isLoaded,
        error: identical(error, unset) ? this.error : error as KidError?,
        challenge: challenge ?? this.challenge,
      );
}

const _playerEmailNeeded = "The player's email is needed to verify their age.";

/// The settings menu's controller: reads the session's permissions and owns the grownup-ask sub-flow.
class SettingsController {
  SettingsController({
    required Client client,
    required String sessionId,
    String? challengeId,
    void Function(String challengeId)? onChallenge,
    SessionStore? sessions,
    AskWatcher? asks,
    int? pollIntervalMs,
    int Function() now = defaultNow,
    SetTimer setTimer = defaultSetTimer,
    ClearTimer clearTimer = defaultClearTimer,
  })  : _client = client,
        _sessionId = sessionId,
        _initialChallengeId = challengeId,
        _onChallenge = onChallenge,
        _sessions = sessions,
        _ownsAsks = asks == null,
        _asks = asks ??
            AskWatcher(
              client: client,
              sessions: sessions,
              pollIntervalMs: pollIntervalMs,
              now: now,
              setTimer: setTimer,
              clearTimer: clearTimer,
            ),
        _local = challengeId != null
            ? SettingsChallengeState(
                status: SettingsChallengeStatus.pending,
                permissions: const [],
                challengeId: challengeId,
                challengeKind: null,
              )
            : null {
    _state = SettingsState(session: null, isLoaded: false, error: null, challenge: _challengeState());
  }

  final Client _client;
  final String _sessionId;
  final String? _initialChallengeId;
  final void Function(String challengeId)? _onChallenge;
  final SessionStore? _sessions;
  final bool _ownsAsks;
  final AskWatcher _asks;

  bool _started = false;
  bool _resumed = false;
  String? _etag;
  void Function()? _unsubscribeSessions;
  void Function()? _unsubscribeAsks;
  void Function()? _detachAsks;
  // The ask while it is being sent, or once sending failed; after that the watcher holds it.
  SettingsChallengeState? _local;

  late SettingsState _state;
  final _listeners = Listeners();

  SettingsState get state => _state;

  void Function() subscribe(void Function() listener) => _listeners.add(listener);

  SettingsChallengeState _challengeState() {
    final local = _local;
    if (local != null) return local;
    final ask = _asks.get(_sessionId);
    if (ask != null) {
      return SettingsChallengeState(
        status: ask.failed ? SettingsChallengeStatus.error : SettingsChallengeStatus.pending,
        permissions: ask.permissions,
        challengeId: ask.challengeId,
        challengeKind: ask.challengeKind,
      );
    }
    return SettingsChallengeState.idle;
  }

  void _commit(SettingsState next) {
    final prev = _state.session;
    _state = next;
    _listeners.emit();
    final session = _state.session;
    if (session != null && !identical(session, prev)) _sessions?.publish(session);
  }

  void _adoptSession(Session session) {
    if (identical(session, _state.session) || session.sessionId != _sessionId) return;
    _etag = null;
    _commit(_state.copyWith(session: session, isLoaded: true, error: null));
  }

  // A restarted controller missed what was published while it was stopped.
  void _catchUpSession() {
    final cached = _state.session != null ? _sessions?.current(_sessionId) : null;
    if (cached != null) _adoptSession(cached);
  }

  void _syncChallenge() => _commit(_state.copyWith(challenge: _challengeState()));

  void _setLocal(SettingsChallengeState? next) {
    _local = next;
    _syncChallenge();
  }

  Future<bool> _loadSession() async {
    try {
      final read = await _client.sessionGet(_sessionId, _etag);
      if (read.notModified) return true;
      final session = read.session;
      // A missing session is a failure here: the session id is a required input, unlike the age gate's resume.
      if (session == null) {
        _commit(_state.copyWith(error: read.notFound ?? toKidError(null)));
        return true;
      }
      _etag = read.etag;
      _commit(_state.copyWith(session: session, isLoaded: true, error: null));
      return true;
    } catch (e) {
      KidLog.error('could not load the session', e);
      _commit(_state.copyWith(error: toKidError(e)));
      return false;
    }
  }

  /// Loads the session and resumes a pending ask. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    _unsubscribeSessions ??= _sessions?.subscribe(_adoptSession);
    _catchUpSession();
    _unsubscribeAsks ??= _asks.subscribe(_syncChallenge);
    _detachAsks ??= _asks.attach(_sessionId, _loadSession);
    if (_ownsAsks) _asks.start();
    unawaited(_loadSession());
    if (!_resumed) {
      _resumed = true;
      final challengeId = _initialChallengeId;
      if (challengeId != null && _asks.get(_sessionId) == null) {
        _asks.watch(_sessionId, challengeId, const [], delay: 0);
      }
      _local = null;
    }
    _syncChallenge();
  }

  /// Turns a player-managed permission on or off.
  Future<KidResult> change(PermissionName name, bool enabled) async {
    final res = await _client.sessionChange(_sessionId, name, enabled);
    final session = res.session;
    if (session == null) return KidResult.failed(res.error ?? toKidError(null));
    _etag = null;
    _commit(_state.copyWith(session: session, isLoaded: true, error: null));
    return const KidResult.ok();
  }

  /// Asks for one or more permissions in a single request: guardian-managed ones are emailed to the grownup
  /// ([approverEmail] when the session has none). A permission with a `verifiedAgeThreshold` needs the player's own
  /// age check instead: without an email this returns `invalidRequest`; call it again with the player's own email.
  Future<KidResult> upgrade(List<PermissionName> names, [String? approverEmail]) async {
    _asks.clear(_sessionId);
    _setLocal(SettingsChallengeState(
      status: SettingsChallengeStatus.sending,
      permissions: names,
      challengeId: null,
      challengeKind: null,
    ));
    ChallengeKind? challengeKind;
    try {
      final challenge = (await _client.sessionUpgrade(_sessionId, names)).challenge;
      if (challenge == null) {
        await _loadSession();
        _setLocal(null);
        return const KidResult.ok();
      }
      challengeKind = settingsChallengeKindOf(challenge.type);
      // Nothing is sent without the player's email; the next call asks again, and this challenge just expires.
      if (challengeKind == ChallengeKind.ageAssurance && (approverEmail == null || approverEmail.isEmpty)) {
        _setLocal(SettingsChallengeState(
          status: SettingsChallengeStatus.error,
          permissions: names,
          challengeId: null,
          challengeKind: challengeKind,
        ));
        return KidResult.failed(localKidError(_playerEmailNeeded));
      }
      final sent = await _client.challengeSendEmail(challenge.challengeId, approverEmail);
      if (!sent.ok) {
        _setLocal(SettingsChallengeState(
          status: SettingsChallengeStatus.error,
          permissions: names,
          challengeId: challenge.challengeId,
          challengeKind: challengeKind,
        ));
        return sent;
      }
      // Reported only after the email is sent, so a resume never picks up an un-emailed challenge.
      _onChallenge?.call(challenge.challengeId);
      _local = null;
      _asks.watch(_sessionId, challenge.challengeId, names, challengeKind: challengeKind);
      return const KidResult.ok();
    } catch (e) {
      KidLog.error('could not start the settings challenge', e);
      _setLocal(SettingsChallengeState(
        status: SettingsChallengeStatus.error,
        permissions: names,
        challengeId: null,
        challengeKind: challengeKind,
      ));
      return KidResult.failed(toKidError(e));
    }
  }

  /// Re-reads the session; permissions can change out of band.
  Future<void> refresh() => _loadSession();

  void destroy() {
    if (_ownsAsks) _asks.stop();
    _detachAsks?.call();
    _detachAsks = null;
    _unsubscribeAsks?.call();
    _unsubscribeAsks = null;
    _unsubscribeSessions?.call();
    _unsubscribeSessions = null;
    _started = false;
  }
}
