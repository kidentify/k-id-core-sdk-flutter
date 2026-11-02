import 'dart:async';
import 'dart:math';

import '../catalog/permissions.dart';
import '../client.dart';
import '../log.dart';
import '../models.dart';
import 'challenge_watch.dart';
import 'session_store.dart';
import 'timers.dart';
import 'types.dart';

const _minPollIntervalMs = 30000;
const _maxPollBackoffMs = 300000;

/// A grownup ask that was emailed and is waiting on an answer; `error` once it failed or expired.
typedef PendingAsk = ({
  bool failed,
  String challengeId,
  List<PermissionName> permissions,
  ChallengeKind? challengeKind,
});

/// The kind of a settings challenge, from its server type; null while the type is unknown.
ChallengeKind? settingsChallengeKindOf(String? type) {
  if (type == null) return null;
  if (type == 'CHALLENGE_SESSION_UPGRADE_BY_AGE_ASSURANCE') return ChallengeKind.ageAssurance;
  if (type == 'CHALLENGE_SESSION_UPGRADE' || type.contains('PARENTAL_CONSENT')) return ChallengeKind.parentalConsent;
  return null;
}

class _Polling {
  _Polling(this.backoff, this.stream);

  int backoff;
  Object? timer;
  bool inFlight = false;
  bool granted = false;
  final ChallengeWatch stream;
}

/// Watches each session's pending grownup ask until it is answered, so a grant reaches the session store whether or
/// not a settings screen is mounted.
class AskWatcher {
  AskWatcher({
    required Client client,
    SessionStore? sessions,
    int? pollIntervalMs,
    int Function() now = defaultNow,
    SetTimer setTimer = defaultSetTimer,
    ClearTimer clearTimer = defaultClearTimer,
  })  : _client = client,
        _sessions = sessions,
        _now = now,
        _setTimer = setTimer,
        _clearTimer = clearTimer,
        _interval = max(_minPollIntervalMs, pollIntervalMs ?? _minPollIntervalMs);

  final Client _client;
  final SessionStore? _sessions;
  final int Function() _now;
  final SetTimer _setTimer;
  final ClearTimer _clearTimer;
  final int _interval;

  bool _started = false;
  final _asks = <String, PendingAsk>{};
  final _polling = <String, _Polling>{};
  final _rereads = <String, Future<bool> Function()>{};
  final _streamed = <String, String>{};
  final _fallbackDelays = <String, int>{};
  final _listeners = Listeners();

  PendingAsk? get(String sessionId) => _asks[sessionId];

  void Function() subscribe(void Function() listener) => _listeners.add(listener);

  void _update(String sessionId, PendingAsk Function(PendingAsk ask) patch) {
    final ask = _asks[sessionId];
    if (ask == null) return;
    _asks[sessionId] = patch(ask);
    _listeners.emit();
  }

  _Polling _pollingFor(String sessionId) => _polling.putIfAbsent(
        sessionId,
        () => _Polling(
          _interval,
          ChallengeWatch(
            client: _client,
            now: _now,
            onStatus: (status) => _handleStatus(sessionId, _streamed[sessionId] ?? '', status),
            onFallback: () => _schedule(sessionId, _fallbackDelays[sessionId] ?? _interval),
          ),
        ),
      );

  void _stopTimer(_Polling p) {
    final timer = p.timer;
    if (timer != null) {
      _clearTimer(timer);
      p.timer = null;
    }
  }

  void _schedule(String sessionId, int delay) {
    if (!_started) return;
    final p = _pollingFor(sessionId);
    _stopTimer(p);
    p.timer = _setTimer(() => unawaited(_poll(sessionId)), delay);
  }

  void _watchAsk(String sessionId, int delay) {
    final ask = _asks[sessionId];
    if (!_started || ask == null || ask.failed) return;
    _fallbackDelays[sessionId] = delay;
    _streamed[sessionId] = ask.challengeId;
    if (!_pollingFor(sessionId).stream.start(ask.challengeId)) _schedule(sessionId, delay);
  }

  // A poll or stream result for an ask the session has since replaced is dropped, so it never lands on the new one.
  bool _isCurrent(String sessionId, String challengeId) => _asks[sessionId]?.challengeId == challengeId;

  Future<bool> _reread(String sessionId) async {
    final attached = _rereads[sessionId];
    if (attached != null) return attached();
    try {
      final read = await _client.sessionGet(sessionId);
      final session = read.session;
      if (session != null) _sessions?.publish(session);
      return true;
    } catch (e) {
      KidLog.error('could not load the session', e);
      return false;
    }
  }

  // The grant only counts once the granted session reached the store, so a failed read is retried, not dropped.
  Future<void> _finishGranted(String sessionId, String challengeId, _Polling p) async {
    p.granted = true;
    final read = await _reread(sessionId);
    if (!_isCurrent(sessionId, challengeId)) return;
    if (!read) {
      p.backoff = min(p.backoff * 2, _maxPollBackoffMs);
      _schedule(sessionId, p.backoff);
      return;
    }
    p.granted = false;
    _asks.remove(sessionId);
    _listeners.emit();
  }

  Future<bool> _handleStatus(String sessionId, String challengeId, ChallengeStatus status) async {
    final ask = _asks[sessionId];
    if (ask == null || ask.challengeId != challengeId || ask.failed) return false;
    final p = _pollingFor(sessionId);
    p.backoff = _interval;
    final named = status.permissions;
    if (ask.permissions.isEmpty && named != null && named.isNotEmpty) {
      _update(
          sessionId,
          (a) => (
                failed: a.failed,
                challengeId: a.challengeId,
                permissions: named,
                challengeKind: a.challengeKind,
              ));
    }
    final kind = settingsChallengeKindOf(status.type);
    if (kind != null && kind != ask.challengeKind) {
      _update(
          sessionId,
          (a) => (
                failed: a.failed,
                challengeId: a.challengeId,
                permissions: a.permissions,
                challengeKind: kind,
              ));
    }
    if (status.status == 'PASS') {
      await _finishGranted(sessionId, challengeId, p);
      return false;
    }
    final deadline = parseTime(status.expiresAt);
    if (status.status == 'FAIL' || (deadline != null && _now() > deadline)) {
      _update(
          sessionId,
          (a) => (
                failed: true,
                challengeId: a.challengeId,
                permissions: a.permissions,
                challengeKind: a.challengeKind,
              ));
      return false;
    }
    return true;
  }

  Future<void> _poll(String sessionId) async {
    final p = _pollingFor(sessionId);
    p.timer = null;
    p.inFlight = true;
    try {
      await _pollOnce(sessionId, p);
    } finally {
      p.inFlight = false;
    }
  }

  Future<void> _pollOnce(String sessionId, _Polling p) async {
    final ask = _asks[sessionId];
    if (ask == null || ask.failed) return;
    if (p.granted) return _finishGranted(sessionId, ask.challengeId, p);
    try {
      final status = await _client.challengeGetStatus(ask.challengeId);
      if (await _handleStatus(sessionId, ask.challengeId, status)) _schedule(sessionId, _interval);
    } catch (e) {
      KidLog.error("could not check for the grownup's answer; will retry", e);
      if (!_isCurrent(sessionId, ask.challengeId)) return;
      p.backoff = min(p.backoff * 2, _maxPollBackoffMs);
      _schedule(sessionId, p.backoff);
    }
  }

  /// Watches [challengeId], replacing the session's earlier ask; without a stream it polls after [delay] ms (one poll
  /// interval by default).
  void watch(
    String sessionId,
    String challengeId,
    List<PermissionName> permissions, {
    int? delay,
    ChallengeKind? challengeKind,
  }) {
    _asks[sessionId] =
        (failed: false, challengeId: challengeId, permissions: permissions, challengeKind: challengeKind);
    final p = _pollingFor(sessionId);
    p.backoff = _interval;
    p.granted = false;
    _stopTimer(p);
    _listeners.emit();
    _watchAsk(sessionId, delay ?? _interval);
  }

  void clear(String sessionId) {
    final p = _polling[sessionId];
    if (p != null) {
      _stopTimer(p);
      p.stream.stop();
    }
    if (_asks.remove(sessionId) != null) _listeners.emit();
  }

  /// While attached, a granted ask is re-read through [reread], so a mounted settings screen keeps its own read.
  /// [reread] resolves false when the read failed, to be retried.
  void Function() attach(String sessionId, Future<bool> Function() reread) {
    _rereads[sessionId] = reread;
    return () {
      if (identical(_rereads[sessionId], reread)) _rereads.remove(sessionId);
    };
  }

  void start() {
    if (_started) return;
    _started = true;
    for (final sessionId in [..._asks.keys]) {
      final p = _pollingFor(sessionId);
      if (!p.inFlight && !p.stream.active) _watchAsk(sessionId, 0);
    }
  }

  void stop() {
    for (final p in _polling.values) {
      _stopTimer(p);
      p.stream.stop();
    }
    _started = false;
  }
}
