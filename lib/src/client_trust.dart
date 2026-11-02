import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A P-256 key that signs DPoP proofs.
abstract interface class DeviceKey {
  Map<String, String> get publicJwk;

  /// Returns the raw 64-byte `r || s` signature JWS expects.
  Future<Uint8List> sign(Uint8List data);
}

abstract interface class DeviceKeyProvider {
  Future<DeviceKey> getKey();
}

/// The platform a mint is for, and the device evidence an app sends with it.
class ClientAttestation {
  const ClientAttestation({required this.platform, this.evidence, this.minted});

  /// `ios`, `android` or `web`.
  final String platform;

  /// The attest request for this mint, bound to SHA-256(nonce.jkt), or null when the device has none to give.
  final Future<Map<String, Object?>?> Function(Uint8List clientDataHash)? evidence;

  /// Called once a mint succeeds, with what was sent and whether k-ID verified it.
  final void Function(Map<String, Object?> sent, bool verified)? minted;
}

/// A call to /fapi as client trust sends it.
typedef FapiResponse = ({bool ok, int status, Map<String, dynamic> data, int? retryAfter});
typedef FapiSend = Future<FapiResponse> Function(
  String path, {
  required String method,
  required Map<String, String> headers,
  Object? body,
});

final _random = Random.secure();

Uint8List randomBytes(int length) => Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

Uint8List sha256Bytes(List<int> data) => Uint8List.fromList(sha256.convert(data).bytes);

String unpaddedBase64Url(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

String _htu(String url) {
  final target = Uri.parse(url);
  return '${target.scheme}://${target.authority}${target.path.isEmpty ? '/' : target.path}';
}

Uint8List _jwkThumbprint(Map<String, String> jwk) =>
    sha256Bytes(utf8.encode('{"crv":"${jwk['crv']}","kty":"${jwk['kty']}","x":"${jwk['x']}","y":"${jwk['y']}"}'));

/// [url] must be absolute.
Future<String> createDPoPProof(
  DeviceKey key,
  String method,
  String url, {
  String? nonce,
  String? accessToken,
  DateTime Function() now = DateTime.now,
}) async {
  final header = {'typ': 'dpop+jwt', 'alg': 'ES256', 'jwk': key.publicJwk};
  final claims = <String, Object>{
    'htm': method,
    'htu': _htu(url),
    'iat': now().millisecondsSinceEpoch ~/ 1000,
    'jti': unpaddedBase64Url(randomBytes(16)),
    if (nonce != null) 'nonce': nonce,
    if (accessToken != null) 'ath': unpaddedBase64Url(sha256Bytes(utf8.encode(accessToken))),
  };
  final signingInput =
      '${unpaddedBase64Url(utf8.encode(jsonEncode(header)))}.${unpaddedBase64Url(utf8.encode(jsonEncode(claims)))}';
  return '$signingInput.${unpaddedBase64Url(await key.sign(Uint8List.fromList(utf8.encode(signingInput))))}';
}

/// Solves the bot check k-ID asks a web mint for, returning its token.
typedef BotCheck = Future<String> Function(Map<String, dynamic> hint);

typedef _Token = ({String clientToken, DateTime expiresAt, String trustLevel});

/// A token is refreshed this long before it expires, so a call never races its expiry.
const _expiryMargin = Duration(seconds: 60);

/// So an outage of the mint endpoints doesn't add two requests to every call.
const _mintCooldown = Duration(seconds: 60);

class ClientTrust {
  ClientTrust({
    required FapiSend send,
    required String Function(String path) resolveUrl,
    required DeviceKeyProvider keys,
    ClientAttestation? attestation,
    BotCheck? botCheck,
    DateTime Function() now = DateTime.now,
  })  : _send = send,
        _botCheck = botCheck,
        _resolveUrl = resolveUrl,
        _keys = keys,
        _attestation = attestation,
        _now = now;

  final FapiSend _send;
  final String Function(String path) _resolveUrl;
  final DeviceKeyProvider _keys;
  final ClientAttestation? _attestation;
  final BotCheck? _botCheck;
  final DateTime Function() _now;

  _Token? _token;
  Future<_Token?>? _minting;
  DateTime _nextMintAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Null when the last mint failed before reaching k-ID (no device key), or did not fail.
  FapiResponse? _failure;

  Future<Map<String, String>> headers(String method, String path) async {
    final token = await _current();
    if (token == null) return {};
    try {
      final key = await _keys.getKey();
      final proof = await createDPoPProof(key, method, _resolveUrl(path), accessToken: token.clientToken, now: _now);
      return {'Kid-Client': token.clientToken, 'DPoP': proof};
    } catch (_) {
      return {};
    }
  }

  /// The token step's failure that leaves calls without a token, with a 429's `retryAfter` as the seconds left
  /// before the next mint; null when there is none.
  FapiResponse? tokenFailure() {
    final failure = _failure;
    if (failure == null || failure.status != 429) return failure;
    final left = (_nextMintAt.difference(_now()).inMilliseconds / 1000).ceil();
    return (ok: failure.ok, status: failure.status, data: failure.data, retryAfter: max(1, left));
  }

  void invalidate() => _token = null;

  Future<String?> trustLevel() async => (await _current())?.trustLevel;

  Future<_Token?> _current() async {
    final token = _token;
    if (token != null && token.expiresAt.subtract(_expiryMargin).isAfter(_now())) return token;
    if (_now().isBefore(_nextMintAt)) return null;
    final minting = _minting ??= _mint().then((token) {
      // A rate limit's Retry-After replaces the cooldown, so the mint is tried again as soon as k-ID allows.
      final retryAfter = _failure?.retryAfter;
      if (token == null) _nextMintAt = _now().add(retryAfter != null ? Duration(seconds: retryAfter) : _mintCooldown);
      return token;
    }).whenComplete(() => _minting = null);
    return _token = await minting;
  }

  Future<_Token?> _mint() async {
    _failure = null;
    try {
      final key = await _keys.getKey();
      final challenge = await _send('/client/challenge', method: 'POST', headers: const {});
      if (!challenge.ok) {
        _failure = challenge;
        return null;
      }
      final nonce = challenge.data['nonce'];
      if (nonce is! String) return null;
      final platform = _attestation?.platform ?? 'web';
      final evidence = _attestation?.evidence;
      final Map<String, Object?> body = (evidence == null
              ? null
              : await evidence(
                  sha256Bytes(utf8.encode('$nonce.${unpaddedBase64Url(_jwkThumbprint(key.publicJwk))}')))) ??
          {'platform': platform};
      final hint = challenge.data['botCheck'];
      // Only the web answers the bot check; an app proves itself with its attestation instead.
      if (hint is Map && platform == 'web') {
        final botCheck = _botCheck;
        if (botCheck == null) return null;
        body['botCheckToken'] = await botCheck(hint.cast<String, dynamic>());
      }
      final proof = await createDPoPProof(key, 'POST', _resolveUrl('/client/attest'), nonce: nonce, now: _now);
      final attest = await _send('/client/attest', method: 'POST', headers: {'DPoP': proof}, body: body);
      if (!attest.ok) {
        _failure = attest;
        return null;
      }
      final data = attest.data;
      final trustLevel = data['trustLevel'] as String? ?? 'basic';
      _attestation?.minted?.call(body, trustLevel == 'verified');
      return (
        clientToken: data['clientToken'] as String,
        expiresAt: DateTime.parse(data['expiresAt'] as String),
        trustLevel: trustLevel,
      );
    } catch (_) {
      return null;
    }
  }
}
