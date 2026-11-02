import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cancel.dart';
import 'catalog/permissions.dart';
import 'client_trust.dart';
import 'errors.dart';
import 'models.dart';
import 'sse.dart';

/// A read of the session, carrying the etag so a caller can make the next read conditional. [notFound] is k-ID's
/// answer when the session no longer exists.
typedef SessionRead = ({Session? session, String? etag, bool notModified, KidError? notFound});

/// The updated session, or a user-recoverable failure with its error.
typedef SessionChangeResult = ({Session? session, KidError? error});

/// The session plus any minted upgrade challenge to email and watch.
typedef SessionUpgradeResult = ({Session? session, Challenge? challenge});

typedef SessionVerifyAgeResult = ({String status, Challenge? challenge});

/// How an opened challenge stream ended: the server closed it (with its reconnect hint, if any), or the connection
/// dropped.
typedef ChallengeStreamEnd = ({bool closed, int? retryMs});

typedef PlatformAgeSignalSource = Future<PlatformAgeSignal?> Function(List<int> ageGates);

/// A declared field: left out to keep what k-ID has, cleared, or set to a value.
sealed class DeclareField<T> {
  const DeclareField();
  const factory DeclareField.keep() = _Keep<T>;
  const factory DeclareField.clear() = _Clear<T>;
  const factory DeclareField.set(T value) = _Set<T>;
}

final class _Keep<T> extends DeclareField<T> {
  const _Keep();
}

final class _Clear<T> extends DeclareField<T> {
  const _Clear();
}

final class _Set<T> extends DeclareField<T> {
  const _Set(this.value);
  final T value;
}

/// The app's one-time integration manifest, applied while you use a test key.
class KidDeclare {
  const KidDeclare({
    required this.permissions,
    required this.supportEmail,
    this.privacyPolicyUrl = const DeclareField.keep(),
    this.termsOfServiceUrl = const DeclareField.keep(),
    this.iconUrl = const DeclareField.keep(),
  });

  /// One per capability the app uses.
  final List<PermissionName> permissions;

  /// The address k-ID's emails give players and parents for help.
  final String supportEmail;
  final DeclareField<String> privacyPolicyUrl;
  final DeclareField<String> termsOfServiceUrl;

  /// A public https link, or an image the app can load (a bundled asset or a file path), which is sent inline.
  final DeclareField<String> iconUrl;
}

/// The /fapi calls the controllers make.
abstract interface class Client {
  /// An absent jurisdiction is resolved server-side from the client IP. A platform age signal stands in for an absent
  /// age.
  Future<AgeResult> ageGateCheck(AgeSignal? age, String? jurisdiction, PlatformAgeSignal? platformAgeSignal);

  /// Whether the server will use a platform age signal from this client.
  Future<bool> platformAgeSignalTrusted();

  /// Asks the platform for the player's age range, where the client has a way to.
  PlatformAgeSignalSource? get platformAgeSignal;

  Future<Requirements> getRequirements(String? jurisdiction);

  /// Pass a prior etag to let an unchanged session 304.
  Future<SessionRead> sessionGet(String sessionId, [String? etag]);

  Future<ChallengeStatus> challengeGetStatus(String challengeId);

  /// Streams the challenge's status, calling [onStatus] with each one, until the stream ends. Throws a [KidError] when
  /// the stream can't be opened; `notFound` means streaming is unavailable, so poll instead.
  Future<ChallengeStreamEnd> challengeStream(
    String challengeId,
    void Function(ChallengeStatus status) onStatus,
    Cancel cancel,
  );

  /// Omit [email] to reach the challenge's existing approver. Re-callable to re-send to a still-pending challenge.
  Future<KidResult> challengeSendEmail(String challengeId, [String? email]);

  Future<SessionChangeResult> sessionChange(String sessionId, PermissionName name, bool enabled);

  Future<SessionUpgradeResult> sessionUpgrade(String sessionId, List<PermissionName> names);

  Future<SessionVerifyAgeResult> sessionVerifyAge(String sessionId);

  /// Declare the app's config (test mode only). Throws on a non-2xx.
  Future<void> declare(KidDeclare input);
}

/// Opens an event stream: [onHeaders] once the response starts, [onText] with each piece of the body as it arrives.
/// Completes when the response ends; throws when the connection fails or [cancel] fires.
typedef EventStreamTransport = Future<({int status, String text})> Function(
  String url,
  Map<String, String> headers,
  Cancel cancel,
  void Function(int status, String? contentType) onHeaders,
  void Function(String text) onText,
);

class ClientOptions {
  const ClientOptions({
    required this.publishableKey,
    required this.baseUrl,
    this.httpClient,
    this.deviceKeys,
    this.headers = const {},
    this.attestation,
    this.botCheck,
    this.eventStream,
    this.readIcon,
    this.platformAgeSignal,
    this.forbidden = ErrorMessage.unauthorizedApp,
  });

  /// Sent as `Authorization: Bearer`.
  final String publishableKey;

  /// The absolute /fapi URL.
  final String baseUrl;
  final http.Client? httpClient;

  /// The device key calls are bound to. Without one, calls are sent unbound.
  final DeviceKeyProvider? deviceKeys;

  /// Sent with every call, such as an app's `Kid-App-Id`.
  final FutureOr<Map<String, String>> headers;

  /// The mint's platform and device evidence.
  final ClientAttestation? attestation;

  /// Solves the bot check k-ID asks a live key's web mint for. Without one, such a mint gets no token.
  final BotCheck? botCheck;
  final EventStreamTransport? eventStream;

  /// Turns a declared icon that k-ID cannot fetch into a data URL.
  final Future<String> Function(String iconUrl)? readIcon;
  final PlatformAgeSignalSource? platformAgeSignal;

  /// The message a 403 carries: an app id or a web origin the key does not allow.
  final ErrorMessage forbidden;
}

/// Retry-After as a whole number of seconds; anything else, an HTTP date included, is left out.
int? parseRetryAfter(String? header) {
  final value = header?.trim();
  if (value == null || !RegExp(r'^\d+$').hasMatch(value)) return null;
  return int.tryParse(value);
}

EventStreamTransport httpEventStream(http.Client client) => (url, headers, cancel, onHeaders, onText) async {
      final request = http.AbortableRequest('GET', Uri.parse(url), abortTrigger: cancel.whenCancelled)
        ..headers.addAll(headers);
      final response = await client.send(request);
      final contentType = response.headers['content-type'];
      onHeaders(response.statusCode, contentType);
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (!ok || contentType == null || !contentType.startsWith('text/event-stream')) {
        return (status: response.statusCode, text: await response.stream.bytesToString());
      }
      await response.stream.transform(utf8.decoder).forEach(onText);
      return (status: response.statusCode, text: '');
    };

typedef _Sent = ({bool ok, int status, Map<String, dynamic> data, String? etag, int? retryAfter});

class FapiClient implements Client {
  FapiClient(this._options)
      : _baseUrl = _options.baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _http = _options.httpClient ?? http.Client() {
    _openEventStream = _options.eventStream ?? httpEventStream(_http);
    final keys = _options.deviceKeys;
    _trust = keys == null
        ? null
        : ClientTrust(
            send: (path, {required method, required headers, body}) async {
              final sent = await _sendRaw(path, method: method, headers: headers, body: body);
              return (ok: sent.ok, status: sent.status, data: sent.data, retryAfter: sent.retryAfter);
            },
            resolveUrl: (path) => '$_baseUrl$path',
            keys: keys,
            attestation: _options.attestation,
            botCheck: _options.botCheck,
          );
  }

  final ClientOptions _options;
  final String _baseUrl;
  final http.Client _http;
  late final EventStreamTransport _openEventStream;
  late final ClientTrust? _trust;

  Map<String, String> get _bearer => {'Authorization': 'Bearer ${_options.publishableKey}'};

  KidError _kidError(
    int status,
    Map<String, dynamic> data, {
    int? retryAfter,
    ErrorMessage notFound = ErrorMessage.sessionNotFound,
    ErrorMessage invalid = ErrorMessage.invalidRequest,
  }) {
    final rawCode = data['error'] as String?;
    final code = toKidErrorCode(rawCode, status);
    return KidError(
      status: status,
      code: code,
      message: resolveErrorMessage(
        rawCode,
        data['errorMessage'] as String?,
        status,
        forbidden: _options.forbidden,
        notFound: notFound,
        invalid: invalid,
      ),
      rawCode: rawCode,
      retryAfter: code == KidErrorCode.rateLimited ? retryAfter : null,
    );
  }

  // A transport failure (offline, DNS, TLS) becomes a synthetic status-0 non-ok, mapped like any other.
  Future<_Sent> _sendRaw(String path,
      {required String method, required Map<String, String> headers, Object? body}) async {
    final http.Response r;
    try {
      final request = http.Request(method, Uri.parse('$_baseUrl$path'))
        ..headers.addAll({
          if (method == 'POST') 'Content-Type': 'application/json',
          ..._bearer,
          ...await _options.headers,
          ...headers,
        });
      if (method == 'POST') request.body = jsonEncode(body ?? const {});
      r = await http.Response.fromStream(await _http.send(request));
    } catch (_) {
      return (ok: false, status: 0, data: <String, dynamic>{}, etag: null, retryAfter: null);
    }
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(utf8.decode(r.bodyBytes));
      data = decoded is Map ? decoded.cast<String, dynamic>() : {};
    } catch (_) {
      data = {};
    }
    return (
      ok: r.statusCode >= 200 && r.statusCode < 300,
      status: r.statusCode,
      data: data,
      etag: r.headers['etag'],
      retryAfter: r.statusCode == 429 ? parseRetryAfter(r.headers['retry-after']) : null,
    );
  }

  // A call that went out without a token and came back 401 reports why it had none: the token step's own failure.
  _Sent? _tokenFailure(int status, Map<String, String> trust) {
    final failure = status == 401 && trust.isEmpty ? _trust?.tokenFailure() : null;
    if (failure == null) return null;
    return (ok: false, status: failure.status, data: failure.data, etag: null, retryAfter: failure.retryAfter);
  }

  Future<_Sent> _trusted(String path,
      {required String method, Map<String, String> headers = const {}, Object? body}) async {
    Future<_Sent> attempt() async {
      final trust = await _trust?.headers(method, path) ?? const <String, String>{};
      final sent = await _sendRaw(path, method: method, headers: {...headers, ...trust}, body: body);
      return _tokenFailure(sent.status, trust) ?? sent;
    }

    final first = await attempt();
    final trust = _trust;
    if (trust == null || first.data['error'] != 'CLIENT_TOKEN_INVALID') return first;
    trust.invalidate();
    return attempt();
  }

  KidError _errorOf(_Sent sent,
          {ErrorMessage notFound = ErrorMessage.sessionNotFound, ErrorMessage invalid = ErrorMessage.invalidRequest}) =>
      _kidError(sent.status, sent.data, retryAfter: sent.retryAfter, notFound: notFound, invalid: invalid);

  @override
  Future<AgeResult> ageGateCheck(AgeSignal? age, String? jurisdiction, PlatformAgeSignal? platformAgeSignal) async {
    final sent = await _trusted('/age-gate/check', method: 'POST', body: {
      ...?age?.toJson(),
      if (jurisdiction != null) 'jurisdiction': jurisdiction,
      if (platformAgeSignal != null) 'platformAgeSignal': platformAgeSignal.toJson(),
    });
    if (!sent.ok) throw _errorOf(sent, invalid: ErrorMessage.invalidAgeSignal);
    return AgeResult.fromJson(sent.data);
  }

  // The server trusts a platform age signal from any app on a test key, and from an attested one on a live key.
  @override
  Future<bool> platformAgeSignalTrusted() async {
    final trust = _trust;
    if (_options.platformAgeSignal == null || trust == null) return false;
    final level = await trust.trustLevel();
    if (level == null) return false;
    return !_options.publishableKey.startsWith('kgp_live_') || level == 'verified';
  }

  @override
  PlatformAgeSignalSource? get platformAgeSignal => _options.platformAgeSignal;

  @override
  Future<Requirements> getRequirements(String? jurisdiction) async {
    final query = jurisdiction != null ? '?jurisdiction=${Uri.encodeQueryComponent(jurisdiction)}' : '';
    final sent = await _trusted('/age-gate/get-requirements$query', method: 'GET');
    if (!sent.ok) throw _errorOf(sent, invalid: ErrorMessage.invalidJurisdiction);
    return Requirements.fromJson(sent.data);
  }

  @override
  Future<SessionRead> sessionGet(String sessionId, [String? etag]) async {
    final sent = await _trusted(
      '/session/get?sessionId=${Uri.encodeQueryComponent(sessionId)}',
      method: 'GET',
      headers: etag != null ? {'If-None-Match': etag} : const {},
    );
    if (sent.status == 304) return (session: null, etag: etag, notModified: true, notFound: null);
    if (!sent.ok) {
      final err = _errorOf(sent);
      // A stale or unknown session is a normal resume outcome, not a throw.
      if (err.code == KidErrorCode.notFound) return (session: null, etag: null, notModified: false, notFound: err);
      throw err;
    }
    final session = Session.fromJson(sent.data);
    return (session: session, etag: session.etag ?? sent.etag, notModified: false, notFound: null);
  }

  @override
  Future<ChallengeStatus> challengeGetStatus(String challengeId) async {
    final sent =
        await _trusted('/challenge/get-status?challengeId=${Uri.encodeQueryComponent(challengeId)}', method: 'GET');
    if (!sent.ok) throw _errorOf(sent, notFound: ErrorMessage.challengeNotFound);
    return ChallengeStatus.fromJson(sent.data);
  }

  @override
  Future<ChallengeStreamEnd> challengeStream(
    String challengeId,
    void Function(ChallengeStatus status) onStatus,
    Cancel cancel,
  ) async {
    final path = '/challenge/stream?challengeId=${Uri.encodeQueryComponent(challengeId)}';
    final parser = SseParser((event) {
      if (event.event != 'status') return;
      final Object? decoded;
      try {
        decoded = jsonDecode(event.data);
      } catch (_) {
        return;
      }
      if (decoded is Map) onStatus(ChallengeStatus.fromJson(decoded.cast<String, dynamic>()));
    });

    var streaming = false;
    var trust = <String, String>{};
    Future<({int status, String text})> open() async {
      streaming = false;
      trust = await _trust?.headers('GET', path) ?? {};
      return _openEventStream(
        '$_baseUrl$path',
        {'Accept': 'text/event-stream', ..._bearer, ...await _options.headers, ...trust},
        cancel,
        (status, contentType) {
          streaming = status >= 200 && status < 300 && (contentType?.startsWith('text/event-stream') ?? false);
        },
        (text) {
          if (streaming) parser.push(text);
        },
      );
    }

    KidError refused(({int status, String text}) res) {
      final failure = _tokenFailure(res.status, trust);
      if (failure != null) return _errorOf(failure, notFound: ErrorMessage.challengeNotFound);
      var data = <String, dynamic>{};
      try {
        final decoded = jsonDecode(res.text);
        if (decoded is Map) data = decoded.cast<String, dynamic>();
      } catch (_) {
        // A refusal that is not JSON maps on its status alone.
      }
      return _kidError(res.status, data, notFound: ErrorMessage.challengeNotFound);
    }

    ({int status, String text}) res;
    try {
      res = await open();
      if (res.status >= 400) {
        final err = refused(res);
        if (_trust == null || err.rawCode != 'CLIENT_TOKEN_INVALID') throw err;
        _trust.invalidate();
        res = await open();
      }
    } on KidError {
      rethrow;
    } catch (_) {
      // A stream that dropped after it opened ends like any other; one that never opened failed to open.
      if (streaming) return (closed: false, retryMs: null);
      throw _kidError(0, const {});
    }
    if (res.status >= 400) throw refused(res);
    // A proxy that answers with something other than a stream can't stream to this client.
    if (!streaming) throw _kidError(0, const {});
    return (closed: true, retryMs: parser.retryMs);
  }

  @override
  Future<KidResult> challengeSendEmail(String challengeId, [String? email]) async {
    final sent = await _trusted('/challenge/send-email', method: 'POST', body: {
      'challengeId': challengeId,
      if (email != null && email.isNotEmpty) 'email': email,
    });
    if (sent.ok) return const KidResult.ok();
    return KidResult.failed(
      _errorOf(sent, notFound: ErrorMessage.challengeNotFound, invalid: ErrorMessage.challengeResolved),
    );
  }

  @override
  Future<SessionChangeResult> sessionChange(String sessionId, PermissionName name, bool enabled) async {
    final sent = await _trusted('/session/change', method: 'POST', body: {
      'sessionId': sessionId,
      'name': name.value,
      'enabled': enabled,
    });
    if (sent.ok) return (session: Session.fromJson(sent.data), error: null);
    return (session: null, error: _errorOf(sent, invalid: ErrorMessage.permissionNotChangeable));
  }

  @override
  Future<SessionUpgradeResult> sessionUpgrade(String sessionId, List<PermissionName> names) async {
    final sent = await _trusted('/session/upgrade', method: 'POST', body: {
      'sessionId': sessionId,
      'requestedPermissions': [
        for (final name in names) {'name': name.value},
      ],
    });
    if (!sent.ok) throw _errorOf(sent);
    final session = sent.data['session'];
    final challenge = sent.data['challenge'];
    return (
      session: session is Map ? Session.fromJson(session.cast<String, dynamic>()) : null,
      challenge: challenge is Map ? Challenge.fromJson(challenge.cast<String, dynamic>()) : null,
    );
  }

  @override
  Future<SessionVerifyAgeResult> sessionVerifyAge(String sessionId) async {
    final sent = await _trusted('/session/verify-age', method: 'POST', body: {'sessionId': sessionId});
    if (!sent.ok) throw _errorOf(sent);
    final challenge = sent.data['challenge'];
    return (
      status: sent.data['status'] as String? ?? '',
      challenge: challenge is Map ? Challenge.fromJson(challenge.cast<String, dynamic>()) : null,
    );
  }

  @override
  Future<void> declare(KidDeclare input) async {
    final body = <String, Object?>{
      'permissions': [
        for (final name in input.permissions) {'name': name.value},
      ],
      'supportEmail': input.supportEmail,
    };
    void field(String key, DeclareField<String> value) {
      switch (value) {
        case _Keep():
          break;
        case _Clear():
          body[key] = null;
        case _Set(:final value):
          body[key] = value;
      }
    }

    field('privacyPolicyUrl', input.privacyPolicyUrl);
    field('termsOfServiceUrl', input.termsOfServiceUrl);
    var icon = input.iconUrl;
    if (icon case _Set(:final value) when value.isNotEmpty) {
      final read = _options.readIcon;
      try {
        icon = DeclareField.set(read != null ? await read(value) : value);
      } catch (e) {
        throw KidError(status: 0, code: KidErrorCode.invalidRequest, message: 'Could not read the app icon: $e');
      }
    }
    field('iconUrl', icon);
    final sent = await _trusted('/declare', method: 'POST', body: body);
    // Declare is dev-time (test mode): the server's validation detail passes through, so the integrator sees e.g.
    // "Unknown permission: chatt" rather than a scrubbed generic string.
    if (!sent.ok) {
      final rawCode = sent.data['error'] as String?;
      final code = toKidErrorCode(rawCode, sent.status);
      throw KidError(
        status: sent.status,
        code: code,
        message: sent.data['errorMessage'] as String? ?? rawCode ?? 'Declare failed.',
        rawCode: rawCode,
        retryAfter: code == KidErrorCode.rateLimited ? sent.retryAfter : null,
      );
    }
  }
}
