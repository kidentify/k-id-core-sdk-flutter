import 'dart:async';
import 'dart:math';

import '../client.dart';
import '../errors.dart';
import '../log.dart';
import '../models.dart';
import 'challenge_watch.dart';
import 'session_store.dart';
import 'timers.dart';
import 'types.dart';
import 'verify_age.dart';

const _minPollIntervalMs = 30000;
const _maxPollBackoffMs = 300000;
const _maxCheckAttempts = 3;
const _checkRetryMs = 1000;

/// The challenge id safe to resume from: only once its email is sent.
String? resumableChallengeId(AgeGateState state) => state.status == KidStatus.pending ? state.challengeId : null;

const _consentTypeMarker = 'PARENTAL_CONSENT';
// Deliberately excludes CHALLENGE_SESSION_UPGRADE_BY_AGE_ASSURANCE, which also contains "AGE_ASSURANCE".
const _assuranceTypeMarker = 'AGE_GATE_AGE_ASSURANCE';

ChallengeKind? _challengeKindOf(String? type) {
  if (type == null || type.contains(_consentTypeMarker)) return ChallengeKind.parentalConsent;
  if (type.contains(_assuranceTypeMarker)) return ChallengeKind.ageAssurance;
  return null;
}

/// The jurisdiction's minimum, access and civil ages, as the age gates to ask the platform for.
///
/// Apple rejects a range shorter than two years, so a minimum age too close to its neighbour is dropped (the check
/// still enforces it). Empty when the ages still cannot make valid gates.
List<int> platformAgeGates(Requirements requirements) {
  List<int>? gates(List<int?> ages) {
    final sorted = {
      for (final a in ages)
        if (a != null && a > 0) a
    }.toList()
      ..sort();
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i] - (i == 0 ? 0 : sorted[i - 1]) < 2) return null;
    }
    return sorted;
  }

  return gates([requirements.minimumAge, requirements.accessAge, requirements.civilAge]) ??
      gates([requirements.accessAge, requirements.civilAge]) ??
      const [];
}

/// One age-gate + consent flow.
class AgeGateController {
  AgeGateController({
    required Client client,
    String? jurisdiction,
    AgeSignal? age,
    String? email,
    String? challengeId,
    String? sessionId,
    PlatformAgeSignalSource? platformAgeSignal,
    SessionStore? sessions,
    int? pollIntervalMs,
    int Function() now = defaultNow,
    SetTimer setTimer = defaultSetTimer,
    ClearTimer clearTimer = defaultClearTimer,
  })  : _client = client,
        _initialSessionId = sessionId,
        _initialChallengeId = challengeId,
        _resuming = challengeId != null || sessionId != null,
        _platformAgeSignal = platformAgeSignal ?? client.platformAgeSignal,
        _sessions = sessions,
        _pollIntervalMs = pollIntervalMs,
        _now = now,
        _setTimer = setTimer,
        _clearTimer = clearTimer,
        _interval = max(_minPollIntervalMs, pollIntervalMs ?? _minPollIntervalMs),
        _propJurisdiction = jurisdiction,
        _propAge = age,
        _propEmail = email,
        _lockedJurisdiction = jurisdiction,
        _lockedAge = age {
    _locked = _resuming;
    _checked = _resuming;
    _backoff = _interval;
    _stream = ChallengeWatch(
      client: client,
      now: now,
      onStatus: (status) async {
        final pending = await _handleStatus(status);
        if (pending) _scheduleWithinDeadline(null);
        return pending;
      },
      onFallback: () => _scheduleWithinDeadline(_fallbackDelay),
    );
    final initial = AgeGateState(
      status: challengeId != null ? KidStatus.pending : KidStatus.running,
      step: null,
      challengeId: challengeId,
      challengeKind: null,
      sessionId: sessionId,
      session: null,
      claimToken: null,
      rawChallengeStatus: challengeId != null ? RawChallengeStatus.pending : null,
      expiresAt: null,
      requirements: null,
      emailProvided: email != null,
      error: null,
    );
    _state = initial.copyWith(step: _computeStep(initial));
  }

  final Client _client;
  final String? _initialSessionId;
  final String? _initialChallengeId;
  final bool _resuming;
  final PlatformAgeSignalSource? _platformAgeSignal;
  final SessionStore? _sessions;
  final int? _pollIntervalMs;
  final int Function() _now;
  final SetTimer _setTimer;
  final ClearTimer _clearTimer;
  final int _interval;
  late final ChallengeWatch _stream;

  String? _propJurisdiction;
  AgeSignal? _propAge;
  String? _propEmail;
  String? _collectedJurisdiction;
  AgeSignal? _collectedAge;
  String? _collectedEmail;

  late bool _locked;
  String? _lockedJurisdiction;
  AgeSignal? _lockedAge;
  late bool _checked;
  bool _checking = false;
  bool _started = false;
  bool _resumeStarted = false;
  bool _polling = false;
  bool _requirementsFetched = false;
  bool _autoResolveFailed = false;
  int _checkAttempts = 0;
  bool _warnedLock = false;
  String? _etag;
  late int _backoff;
  Object? _timer;
  bool _platformAsked = false;
  bool _askingPlatform = false;
  PlatformAgeSignal? _platformSignal;
  void Function()? _unsubscribeSessions;
  int _fallbackDelay = 0;

  late AgeGateState _state;
  final _listeners = Listeners();
  ({String sessionId, VerifyAgeController controller})? _verifyAge;

  AgeGateState get state => _state;

  void Function() subscribe(void Function() listener) => _listeners.add(listener);

  /// Verifies the player is an adult on the established session; null until the gate passes. Nothing is sent until
  /// its `start()`.
  VerifyAgeController? get sessionVerifyAge => _verifyAge?.controller;

  void _syncVerifyAge() {
    final sessionId = _state.status == KidStatus.pass ? _state.sessionId : null;
    if (sessionId == null || _verifyAge?.sessionId == sessionId) return;
    _verifyAge?.controller.destroy();
    _verifyAge = (
      sessionId: sessionId,
      controller: VerifyAgeController(
        client: _client,
        sessionId: sessionId,
        civilAge: _sessionCivilAge,
        onSession: (session) {
          _etag = null;
          _commit((s) => s.copyWith(session: session));
        },
        pollIntervalMs: _pollIntervalMs,
        now: _now,
        setTimer: _setTimer,
        clearTimer: _clearTimer,
      ),
    );
  }

  Future<int?> _sessionCivilAge() async {
    final current = _state.requirements;
    if (current != null) return current.civilAge;
    final jurisdiction = _state.session?.jurisdiction;
    if (jurisdiction == null) return null;
    final requirements = await _client.getRequirements(jurisdiction);
    _commit((s) => s.copyWith(requirements: requirements));
    return requirements.civilAge;
  }

  // A resumed session never ran the gate's requirements fetch; fetch them for its jurisdiction.
  void _fetchSessionRequirements(Session? session) {
    final jurisdiction = session?.jurisdiction;
    if (_state.requirements != null || jurisdiction == null) return;
    _client.getRequirements(jurisdiction).then(
          (requirements) => _commit((s) => s.copyWith(requirements: requirements)),
          onError: (Object e) => KidLog.error('could not load the requirements', e),
        );
  }

  // A user selection wins over the input so a picker choice overrides an unresolved `auto`.
  String? _effectiveJurisdiction() => _locked ? _lockedJurisdiction : (_collectedJurisdiction ?? _propJurisdiction);
  AgeSignal? _effectiveAge() => _locked ? _lockedAge : (_propAge ?? _collectedAge);
  String? _effectiveEmail() => _propEmail ?? _collectedEmail;
  String? _jurisdictionArg() {
    final j = _effectiveJurisdiction();
    return j != null && j.toLowerCase() != 'auto' ? j : null;
  }

  // The picker is needed when there is no concrete jurisdiction and either none was given or `auto` could not be
  // resolved server-side. An unresolved `auto` still gets to try first.
  bool _needJurisdiction() {
    if (_jurisdictionArg() != null) return false;
    return _effectiveJurisdiction() == null || _autoResolveFailed;
  }

  AgeGateStep? _computeStep(AgeGateState s) {
    if (s.status != KidStatus.running) return null;
    if (_needJurisdiction()) return AgeGateStep.jurisdiction;
    if (s.challengeId != null) {
      return s.challengeKind == ChallengeKind.ageAssurance ? AgeGateStep.ageAssurance : AgeGateStep.parentalConsent;
    }
    // The age step waits while the platform may still supply the age instead.
    if (!_checked && _effectiveAge() == null && _platformSignal == null) {
      return _platformAgeSignal != null && !_platformAsked ? AgeGateStep.checking : AgeGateStep.age;
    }
    return AgeGateStep.checking;
  }

  void _commit([AgeGateState Function(AgeGateState s)? patch]) {
    final prev = _state.session;
    final next = patch == null ? _state : patch(_state);
    _state = next.copyWith(step: _computeStep(next));
    _syncVerifyAge();
    _listeners.emit();
    final session = _state.session;
    if (session != null && !identical(session, prev)) _sessions?.publish(session);
  }

  void _adoptSession(Session session) {
    if (identical(session, _state.session) || session.sessionId != _state.sessionId) return;
    _etag = null;
    _commit((s) => s.copyWith(session: session));
  }

  // A restarted gate missed what was published while it was stopped.
  void _catchUpSession() {
    final sessionId = _state.sessionId;
    final cached = _state.session != null && sessionId != null ? _sessions?.current(sessionId) : null;
    if (cached != null) _adoptSession(cached);
  }

  void _stopTimer() {
    final timer = _timer;
    if (timer != null) {
      _clearTimer(timer);
      _timer = null;
    }
  }

  // A null delay waits on the stream alone.
  void _schedule(int? delay) {
    if (!_started) return;
    _stopTimer();
    if (delay != null) _timer = _setTimer(_poll, delay);
  }

  void _watch(int delay) {
    final challengeId = _state.challengeId;
    if (!_started || challengeId == null) return;
    _fallbackDelay = delay;
    _scheduleWithinDeadline(_stream.start(challengeId) ? null : delay);
  }

  void _rearm() {
    if (_polling || _timer != null || _stream.active || _state.challengeId == null) return;
    if (_state.status != KidStatus.pending) return;
    _backoff = _interval;
    _watch(0);
  }

  void _scheduleWithinDeadline(int? delay) {
    final deadline = parseTime(_state.expiresAt);
    if (deadline != null) {
      final remaining = deadline - _now();
      if (remaining <= 0) {
        _commit((s) => s.copyWith(rawChallengeStatus: RawChallengeStatus.fail));
        _fail(KidStatus.fail, 'challenge expired');
        return;
      }
      delay = delay == null ? remaining : min(delay, remaining);
    }
    _schedule(delay);
  }

  void _maybeFetchRequirements() {
    if (!_started || _requirementsFetched) return;
    // Nothing to fetch until we can name a jurisdiction: no concrete one, and either none given or `auto` already
    // failed (waiting on the picker). An unresolved `auto` still probes the server once.
    if (_jurisdictionArg() == null && (_effectiveJurisdiction() == null || _autoResolveFailed)) return;
    _requirementsFetched = true;
    _client.getRequirements(_jurisdictionArg()).then((requirements) {
      _commit((s) => s.copyWith(requirements: requirements));
      _maybeAskPlatform(requirements);
      _maybeCheck();
    }, onError: (Object e) {
      // `auto` could not be resolved server-side: fall back to the picker and let it retry per selection.
      if (_jurisdictionArg() == null && e is KidError && e.rawCode == 'CANNOT_RESOLVE_JURISDICTION') {
        _autoResolveFailed = true;
        _requirementsFetched = false;
        _commit();
        return;
      }
      _fail(KidStatus.error, e);
    });
  }

  void _maybeAskPlatform(Requirements requirements) {
    final ask = _platformAgeSignal;
    if (ask == null || _platformAsked) return;
    _platformAsked = true;
    final gates = platformAgeGates(requirements);
    if (_effectiveAge() != null ||
        !requirements.approvedAgeCollectionMethods.contains('platform-account') ||
        gates.isEmpty) {
      _commit();
      return;
    }
    _askingPlatform = true;
    unawaited(() async {
      if (await _client.platformAgeSignalTrusted()) {
        _platformSignal = await ask(gates).then<PlatformAgeSignal?>((s) => s, onError: (Object _) => null);
      }
      _askingPlatform = false;
      _commit();
      _maybeCheck();
    }());
  }

  void _maybeCheck() {
    if (!_started || _checked || _checking || _resuming || _askingPlatform) return;
    if (_effectiveAge() == null && _platformSignal == null) return;
    if (_state.requirements == null) return;
    unawaited(_runCheck());
  }

  Future<void> _runCheck() async {
    // Capture the inputs before locking: once locked, the effective values read back the locked ones.
    _lockedJurisdiction = _effectiveJurisdiction();
    _lockedAge = _effectiveAge();
    _checking = true;
    _locked = true;
    _commit((s) => s.copyWith(status: KidStatus.running));
    try {
      final res = await _client.ageGateCheck(_lockedAge, _jurisdictionArg(), _platformSignal);
      _checked = true;
      _checking = false;
      if (res.status == 'PROHIBITED') {
        _commit((s) => s.copyWith(status: KidStatus.prohibited, session: null, challengeId: null));
        return;
      }
      if (res.status == 'PASS') {
        _commit((s) => s.copyWith(
              status: KidStatus.pass,
              session: res.session,
              sessionId: res.session?.sessionId,
              challengeId: null,
              claimToken: res.claimToken,
            ));
        return;
      }
      // PASS_WITH_CHALLENGE is treated as CHALLENGE.
      final challenge = res.challenge;
      final kind = challenge != null ? _challengeKindOf(challenge.type) : null;
      if (challenge != null && kind != null) {
        _commit((s) => s.copyWith(
              status: KidStatus.running,
              challengeId: challenge.challengeId,
              challengeKind: kind,
              rawChallengeStatus: RawChallengeStatus.pending,
              claimToken: res.claimToken,
            ));
        return;
      }
      _fail(KidStatus.error,
          challenge?.type != null ? 'unsupported challenge type ${challenge!.type}' : 'challenge without an id');
    } catch (e) {
      _checking = false;
      final status = e is KidError ? e.status : null;
      final transient = status == null || status >= 500;
      _checkAttempts += 1;
      if (transient && _checkAttempts < _maxCheckAttempts) {
        if (!_started) return;
        _stopTimer();
        _timer = _setTimer(() => unawaited(_runCheck()), _checkRetryMs);
        return;
      }
      _checked = true;
      _fail(KidStatus.error, e);
    }
  }

  void _fail(KidStatus status, Object? detail) {
    if (status == KidStatus.error) KidLog.error('age gate error', detail);
    _stopTimer();
    _stream.stop();
    _commit((s) => s.copyWith(status: status, error: status == KidStatus.error ? toKidError(detail) : null));
  }

  /// Sends the challenge email. Valid only after a challenge exists; re-callable to re-send a correction.
  Future<KidResult> submit() async {
    final challengeId = _state.challengeId;
    if (challengeId == null) {
      KidLog.warn('submit() called before a challenge exists; nothing to send.');
      return KidResult.failed(localKidError());
    }
    final email = _effectiveEmail();
    if (email == null || email.isEmpty) {
      KidLog.warn('submit() called without an email; provide the email input or show KidAskAnAdult / KidVerifyAge.');
      return KidResult.failed(localKidError());
    }
    final KidResult res;
    try {
      res = await _client.challengeSendEmail(challengeId, email);
    } catch (e) {
      return KidResult.failed(toKidError(e));
    }
    if (res.ok) {
      _backoff = _interval;
      _commit((s) => s.copyWith(status: KidStatus.pending, rawChallengeStatus: RawChallengeStatus.pending));
      _watch(_interval);
      return res;
    }
    KidLog.error('could not send the challenge email', res.error);
    return res;
  }

  void _poll() {
    _timer = null;
    _polling = true;
    unawaited(_pollOnce().whenComplete(() => _polling = false));
  }

  Future<void> _pollOnce() async {
    final challengeId = _state.challengeId;
    if (challengeId == null) return;
    try {
      final status = await _client.challengeGetStatus(challengeId);
      _backoff = _interval;
      if (await _handleStatus(status)) _scheduleWithinDeadline(_stream.active ? null : _interval);
    } catch (e) {
      KidLog.error('poll failed; will retry', e);
      _backoff = min(_backoff * 2, _maxPollBackoffMs);
      _scheduleWithinDeadline(_stream.active ? null : _backoff);
    }
  }

  Future<bool> _handleStatus(ChallengeStatus status) async {
    if (_state.challengeKind == null && status.type != null) {
      final kind = _challengeKindOf(status.type);
      if (kind != null) _commit((s) => s.copyWith(challengeKind: kind));
    }
    if (status.status == 'PASS') {
      final sessionId = status.sessionId ?? _state.sessionId;
      var session = _state.session;
      if (sessionId != null) {
        final read = await _client.sessionGet(sessionId);
        _etag = read.etag;
        session = read.session ?? session;
      }
      _stopTimer();
      _stream.stop();
      _commit((s) => s.copyWith(
            status: KidStatus.pass,
            rawChallengeStatus: RawChallengeStatus.pass,
            session: session,
            sessionId: sessionId,
          ));
      _fetchSessionRequirements(session);
      return false;
    }
    if (status.status == 'FAIL') {
      _commit((s) => s.copyWith(rawChallengeStatus: RawChallengeStatus.fail));
      _fail(KidStatus.fail, 'challenge failed');
      return false;
    }
    final deadline = parseTime(status.expiresAt);
    if (deadline != null && _now() > deadline) {
      _commit((s) => s.copyWith(rawChallengeStatus: RawChallengeStatus.fail));
      _fail(KidStatus.fail, 'challenge expired');
      return false;
    }
    final raw = status.status == 'IN_PROGRESS' ? RawChallengeStatus.inProgress : RawChallengeStatus.pending;
    _commit((s) => s.copyWith(rawChallengeStatus: raw, expiresAt: status.expiresAt));
    return true;
  }

  /// Re-reads the session; permissions can change out of band. An unchanged session is a cheap 304.
  Future<void> refreshSession() async {
    final sessionId = _state.sessionId;
    if (sessionId == null) return;
    final SessionRead read;
    try {
      read = await _client.sessionGet(sessionId, _etag);
    } catch (e) {
      throw toKidError(e);
    }
    if (read.notModified) return;
    _etag = read.etag;
    final session = read.session;
    if (session != null) _commit((s) => s.copyWith(session: session));
  }

  Future<void> _resume() async {
    final sessionId = _initialSessionId;
    if (sessionId != null) {
      try {
        final read = await _client.sessionGet(sessionId);
        _etag = read.etag;
        final session = read.session;
        if (session != null) {
          _commit((s) => s.copyWith(
                status: KidStatus.pass,
                rawChallengeStatus: RawChallengeStatus.pass,
                session: session,
                sessionId: sessionId,
              ));
          _fetchSessionRequirements(session);
          return;
        }
        _fail(KidStatus.error, 'resumed session not found');
      } catch (e) {
        _fail(KidStatus.error, e);
      }
      return;
    }
    if (_initialChallengeId != null) {
      _backoff = _interval;
      _watch(0);
    }
  }

  /// Kicks off network work (the check, or the resume). Idempotent; no request is sent before it.
  void start() {
    if (_started) return;
    _started = true;
    _unsubscribeSessions ??= _sessions?.subscribe(_adoptSession);
    _catchUpSession();
    if (_resuming) {
      if (_resumeStarted) {
        _rearm();
      } else {
        _resumeStarted = true;
        unawaited(_resume());
      }
      return;
    }
    _maybeFetchRequirements();
    _maybeCheck();
    _rearm();
  }

  /// Pushes the declarative inputs. Locked age and jurisdiction changes are ignored.
  void configure({String? jurisdiction, AgeSignal? age, String? email}) {
    if (_resuming) return;
    _propEmail = email;
    if (_locked) {
      final jurisdictionChanged = jurisdiction != null && jurisdiction != _lockedJurisdiction;
      final ageChanged = age != null && age != _lockedAge;
      if ((jurisdictionChanged || ageChanged) && !_warnedLock) {
        _warnedLock = true;
        KidLog.warn('age/jurisdiction ignored: an active challenge already exists for this session.');
      }
      _commit((s) => s.copyWith(emailProvided: email != null));
      return;
    }
    _propJurisdiction = jurisdiction;
    _propAge = age;
    _maybeFetchRequirements();
    _maybeCheck();
    _commit((s) => s.copyWith(emailProvided: email != null));
  }

  void setJurisdiction(String code) {
    if (_locked) return;
    _collectedJurisdiction = code;
    _maybeFetchRequirements();
    _maybeCheck();
    _listeners.emit();
  }

  void setAge(AgeSignal signal) {
    if (_locked) return;
    _collectedAge = signal;
    _maybeCheck();
    _listeners.emit();
  }

  void setEmail(String email) {
    _collectedEmail = email;
    _listeners.emit();
  }

  /// The integration config could not be declared: surface `error`.
  void declarationFailed(Object? error) =>
      _commit((s) => s.copyWith(status: KidStatus.error, error: toKidError(error)));

  void destroy() {
    _verifyAge?.controller.destroy();
    // Stop watching and allow a later start() to re-arm it, so a remount resumes watching instead of leaving it dead.
    _stopTimer();
    _unsubscribeSessions?.call();
    _unsubscribeSessions = null;
    _stream.stop();
    _started = false;
  }
}
