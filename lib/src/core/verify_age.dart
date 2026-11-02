import 'dart:async';
import 'dart:math';

import '../client.dart';
import '../errors.dart';
import '../log.dart';
import '../models.dart';
import 'challenge_watch.dart';
import 'timers.dart';
import 'types.dart';

const _minPollIntervalMs = 30000;
const _maxPollBackoffMs = 300000;

/// Where session age verification is: checking the session, or waiting for the player's email.
enum VerifyAgeStep { checking, email }

class VerifyAgeState {
  const VerifyAgeState({
    required this.status,
    required this.step,
    required this.challengeId,
    required this.rawChallengeStatus,
    required this.expiresAt,
    required this.error,
  });

  /// `running`, `pending`, `pass`, `fail` or `error`.
  final KidStatus status;
  final VerifyAgeStep? step;
  final String? challengeId;
  final RawChallengeStatus? rawChallengeStatus;

  /// The challenge's deadline, or null when it has none. The flow moves to `fail` at this time.
  final String? expiresAt;

  /// Why the check ended in `error`: a k-ID API error as is, and any other failure as `unavailable`.
  final KidError? error;

  VerifyAgeState copyWith({
    KidStatus? status,
    Object? step = unset,
    Object? challengeId = unset,
    Object? rawChallengeStatus = unset,
    Object? expiresAt = unset,
    Object? error = unset,
  }) =>
      VerifyAgeState(
        status: status ?? this.status,
        step: identical(step, unset) ? this.step : step as VerifyAgeStep?,
        challengeId: identical(challengeId, unset) ? this.challengeId : challengeId as String?,
        rawChallengeStatus:
            identical(rawChallengeStatus, unset) ? this.rawChallengeStatus : rawChallengeStatus as RawChallengeStatus?,
        expiresAt: identical(expiresAt, unset) ? this.expiresAt : expiresAt as String?,
        error: identical(error, unset) ? this.error : error as KidError?,
      );
}

const _initial = VerifyAgeState(
  status: KidStatus.running,
  step: VerifyAgeStep.checking,
  challengeId: null,
  rawChallengeStatus: null,
  expiresAt: null,
  error: null,
);

/// Verifies the player is an adult on an established session.
class VerifyAgeController {
  VerifyAgeController({
    required Client client,
    required String sessionId,
    required Future<int?> Function() civilAge,
    void Function(Session session)? onSession,
    int? pollIntervalMs,
    int Function() now = defaultNow,
    SetTimer setTimer = defaultSetTimer,
    ClearTimer clearTimer = defaultClearTimer,
  })  : _client = client,
        _sessionId = sessionId,
        _civilAge = civilAge,
        _onSession = onSession,
        _now = now,
        _setTimer = setTimer,
        _clearTimer = clearTimer,
        _interval = max(_minPollIntervalMs, pollIntervalMs ?? _minPollIntervalMs) {
    _backoff = _interval;
    _stream = ChallengeWatch(
      client: client,
      now: now,
      onStatus: (status) async {
        final pending = await _handleStatus(status);
        if (pending) _schedule(null);
        return pending;
      },
      onFallback: () => _schedule(_fallbackDelay),
    );
  }

  final Client _client;
  final String _sessionId;
  final Future<int?> Function() _civilAge;
  final void Function(Session session)? _onSession;
  final int Function() _now;
  final SetTimer _setTimer;
  final ClearTimer _clearTimer;
  final int _interval;
  late final ChallengeWatch _stream;

  bool _started = false;
  bool _checked = false;
  bool _polling = false;
  bool _confirming = false;
  int _confirmation = 0;
  String? _collectedEmail;
  late int _backoff;
  Object? _timer;
  int _fallbackDelay = 0;

  VerifyAgeState _state = _initial;
  final _listeners = Listeners();

  VerifyAgeState get state => _state;

  void Function() subscribe(void Function() listener) => _listeners.add(listener);

  void _commit(VerifyAgeState next) {
    _state = next;
    _listeners.emit();
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
    final deadline = parseTime(_state.expiresAt);
    if (deadline != null) {
      final remaining = deadline - _now();
      if (remaining <= 0) {
        _finish(KidStatus.fail);
        return;
      }
      delay = delay == null ? remaining : min(delay, remaining);
    }
    if (delay != null) _timer = _setTimer(_poll, delay);
  }

  void _watch(int delay) {
    final challengeId = _state.challengeId;
    if (!_started || challengeId == null) return;
    _fallbackDelay = delay;
    _schedule(_stream.start(challengeId) ? null : delay);
  }

  void _finish(KidStatus status, [Object? detail]) {
    if (status == KidStatus.error) KidLog.error('age verification error', detail);
    _stopTimer();
    _stream.stop();
    _commit(_state.copyWith(
      status: status,
      step: null,
      rawChallengeStatus: status == KidStatus.fail ? RawChallengeStatus.fail : _state.rawChallengeStatus,
      error: status == KidStatus.error ? toKidError(detail) : null,
    ));
  }

  void _scheduleConfirm(int delay) {
    if (!_started) return;
    _stopTimer();
    _timer = _setTimer(() {
      _timer = null;
      unawaited(_confirmPass());
    }, delay);
  }

  // k-ID reporting a pass is not enough: the session itself must now prove an adult.
  // A remount can start a newer confirmation while an older read is still in flight; only the newest may land.
  Future<void> _confirmPass() async {
    final id = ++_confirmation;
    _confirming = true;
    int? verifiedAge;
    int? civilAge;
    try {
      final read = await _client.sessionGet(_sessionId);
      if (id != _confirmation) return;
      final session = read.session;
      if (session != null) _onSession?.call(session);
      verifiedAge = session?.ageVerification?.verifiedAge;
      civilAge = await _civilAge();
      if (id != _confirmation) return;
    } catch (e) {
      if (id != _confirmation) return;
      KidLog.error('could not re-read the session after verifying age; will retry', e);
      _backoff = min(_backoff * 2, _maxPollBackoffMs);
      _commit(_state.copyWith(status: KidStatus.error, step: null, error: toKidError(e)));
      _scheduleConfirm(_backoff);
      return;
    }
    _confirming = false;
    _backoff = _interval;
    if (verifiedAge != null && civilAge != null && verifiedAge >= civilAge) {
      _commit(_state.copyWith(
        status: KidStatus.pass,
        step: null,
        error: null,
        rawChallengeStatus: _state.challengeId != null ? RawChallengeStatus.pass : null,
      ));
      return;
    }
    _finish(KidStatus.fail);
  }

  Future<void> _check() async {
    _checked = true;
    try {
      final res = await _client.sessionVerifyAge(_sessionId);
      if (res.status == 'PASS') {
        await _confirmPass();
        return;
      }
      if (res.status == 'FAIL') {
        _finish(KidStatus.fail);
        return;
      }
      final challenge = res.challenge;
      if (challenge == null) {
        _finish(KidStatus.error, 'challenge without an id');
        return;
      }
      _commit(_state.copyWith(
        step: VerifyAgeStep.email,
        challengeId: challenge.challengeId,
        rawChallengeStatus: RawChallengeStatus.pending,
      ));
    } catch (e) {
      _finish(KidStatus.error, e);
    }
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
      if (await _handleStatus(status)) _schedule(_stream.active ? null : _interval);
    } catch (e) {
      KidLog.error('age verification poll failed; will retry', e);
      _backoff = min(_backoff * 2, _maxPollBackoffMs);
      _schedule(_stream.active ? null : _backoff);
    }
  }

  Future<bool> _handleStatus(ChallengeStatus status) async {
    if (status.status == 'PASS') {
      _stopTimer();
      _stream.stop();
      await _confirmPass();
      return false;
    }
    final deadline = parseTime(status.expiresAt);
    if (status.status == 'FAIL' || (deadline != null && _now() > deadline)) {
      _finish(KidStatus.fail);
      return false;
    }
    _commit(_state.copyWith(
      rawChallengeStatus: status.status == 'IN_PROGRESS' ? RawChallengeStatus.inProgress : RawChallengeStatus.pending,
      expiresAt: status.expiresAt,
    ));
    return true;
  }

  void start() {
    // A finished fail or error starts over with a fresh check, so showing the widget again tries again.
    if (_state.status == KidStatus.fail || (_state.status == KidStatus.error && !_confirming)) {
      _stopTimer();
      _started = true;
      _backoff = _interval;
      _commit(_initial);
      unawaited(_check());
      return;
    }
    if (_started) return;
    _started = true;
    if (!_checked) {
      unawaited(_check());
      return;
    }
    if (_polling || _timer != null || _stream.active) return;
    if (_confirming) {
      _scheduleConfirm(0);
    } else if (_state.status == KidStatus.pending) {
      _watch(0);
    }
  }

  void setEmail(String email) => _collectedEmail = email;

  Future<KidResult> submit() async {
    final challengeId = _state.challengeId;
    if (challengeId == null || (_state.status != KidStatus.running && _state.status != KidStatus.pending)) {
      KidLog.warn('submit() called before a challenge exists; nothing to send.');
      return KidResult.failed(localKidError());
    }
    final email = _collectedEmail;
    if (email == null || email.isEmpty) {
      KidLog.warn('submit() called without an email; pass one to verifyAge.submit or show KidSessionVerifyAge.');
      return KidResult.failed(localKidError());
    }
    final res = await _client.challengeSendEmail(challengeId, email);
    if (!res.ok) {
      KidLog.error('could not send the verification email', res.error);
      return res;
    }
    _backoff = _interval;
    _commit(_state.copyWith(status: KidStatus.pending, step: null));
    _watch(_interval);
    return const KidResult.ok();
  }

  void destroy() {
    _stopTimer();
    _stream.stop();
    _started = false;
  }
}
