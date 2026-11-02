import 'dart:async';

import '../cancel.dart';
import '../client.dart';
import '../errors.dart';
import '../log.dart';
import '../models.dart';
import 'timers.dart';

const _maxFailedOpens = 2;
const _reconnectBaseMs = 1000;
const _reconnectMaxMs = 30000;
// A stream the server ends sooner than this reconnects with backoff, so a challenge the server already counts as
// expired can't spin while this device's clock still says it is live.
const _minHealthyStreamMs = 1000;

/// Watches a challenge's status over the server's event stream, reconnecting as needed, and falls back to polling
/// when streaming is unavailable (404) or fails to open twice in a row.
class ChallengeWatch {
  ChallengeWatch({
    required Client client,
    required Future<bool> Function(ChallengeStatus status) onStatus,
    required void Function() onFallback,
    int Function() now = defaultNow,
    int reconnectBaseMs = _reconnectBaseMs,
  })  : _client = client,
        _onStatus = onStatus,
        _onFallback = onFallback,
        _now = now,
        _base = reconnectBaseMs,
        _backoff = reconnectBaseMs;

  final Client _client;
  final Future<bool> Function(ChallengeStatus status) _onStatus;
  final void Function() _onFallback;
  final int Function() _now;
  final int _base;

  String? _challengeId;
  bool _fellBack = false;
  // One per start(); cancelling it ends every open of that watch.
  Cancel? _watch;
  Timer? _timer;
  int _failedOpens = 0;
  int _backoff;
  Future<void> _handled = Future.value();

  bool get active => _watch != null;

  /// Streams the challenge's status. Returns false once it has fallen back to polling, which the caller then runs.
  bool start(String id) {
    if (id != _challengeId) {
      stop();
      _challengeId = id;
      _fellBack = false;
      _failedOpens = 0;
      _backoff = _base;
    }
    if (_fellBack) return false;
    if (_watch != null) return true;
    final watch = _watch = Cancel();
    _open(watch);
    return true;
  }

  void stop() {
    _watch?.cancel();
    _watch = null;
    _timer?.cancel();
    _timer = null;
  }

  void _retry(Cancel current, int delay) {
    _timer = Timer(Duration(milliseconds: delay), () {
      _timer = null;
      if (identical(_watch, current)) _open(current);
    });
  }

  void _retryWithBackoff(Cancel current) {
    _retry(current, _backoff);
    _backoff = (_backoff * 2).clamp(0, _reconnectMaxMs);
  }

  void _open(Cancel current) {
    final id = _challengeId;
    if (id == null) return;
    final openedAt = _now();
    var snapshot = false;
    _client.challengeStream(id, (status) {
      snapshot = true;
      _handled = _handled.then((_) async {
        if (!identical(_watch, current)) return;
        var keepWatching = true;
        try {
          keepWatching = await _onStatus(status);
        } catch (e) {
          // The stream re-sends the status on reconnect, so a failed handling is retried then.
          KidLog.error('could not handle a challenge status; will retry', e);
        }
        if (!keepWatching && identical(_watch, current)) stop();
      });
    }, current).then((end) async {
      await _handled;
      if (!identical(_watch, current)) return;
      // A proxy can pass the headers and hold or drop the body, so an open only counts once a status arrives.
      if (!snapshot) return _failOpen(current);
      _failedOpens = 0;
      if (end.closed && _now() - openedAt >= _minHealthyStreamMs) {
        _backoff = _base;
        _retry(current, end.retryMs ?? 0);
        return;
      }
      _retryWithBackoff(current);
    }, onError: (Object e) {
      if (!identical(_watch, current)) return;
      _failOpen(current, unavailable: e is KidError && e.code == KidErrorCode.notFound);
    });
  }

  void _failOpen(Cancel current, {bool unavailable = false}) {
    _failedOpens += 1;
    if (unavailable || _failedOpens >= _maxFailedOpens) {
      stop();
      _fellBack = true;
      _onFallback();
      return;
    }
    _retryWithBackoff(current);
  }
}
