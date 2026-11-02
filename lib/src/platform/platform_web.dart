import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../client.dart';
import '../client_trust.dart';
import '../errors.dart';

extension type _KeyPair._(JSObject _) implements JSObject {
  external web.CryptoKey get publicKey;
  external web.CryptoKey get privateKey;
}

const _dbName = 'k-id-core';
const _dbStore = 'device-keys';
const _dbKey = 'dpop';

extension type _StoredKey._(JSObject _) implements JSObject {
  external factory _StoredKey({web.CryptoKey privateKey, JSObject publicJwk});
  external JSAny? get privateKey;
  external JSObject? get publicJwk;
}

Future<T?> _settled<T extends JSAny?>(web.IDBRequest request) {
  final done = Completer<T?>();
  request.onsuccess = ((web.Event _) => done.complete(request.result as T?)).toJS;
  request.onerror = ((web.Event _) => done.completeError(StateError('IndexedDB: ${request.error?.message}'))).toJS;
  return done.future;
}

Future<web.IDBDatabase> _openKeyStore(web.IDBFactory factory) {
  final done = Completer<web.IDBDatabase>();
  final request = factory.open(_dbName, 1);
  request.onupgradeneeded = ((web.Event _) => (request.result as web.IDBDatabase).createObjectStore(_dbStore)).toJS;
  request.onsuccess = ((web.Event _) => done.complete(request.result as web.IDBDatabase)).toJS;
  request.onerror = ((web.Event _) => done.completeError(StateError('IndexedDB: ${request.error?.message}'))).toJS;
  return done.future;
}

// Reading `indexedDB` itself throws a SecurityError where site data is blocked or in a sandboxed iframe.
web.IDBFactory? _keyStoreFactory() {
  try {
    return web.window.indexedDB;
  } catch (_) {
    return null;
  }
}

Future<_StoredKey> _generateKey() async {
  final subtle = web.window.crypto.subtle;
  final algorithm = {'name': 'ECDSA', 'namedCurve': 'P-256'}.jsify()! as JSObject;
  final pair =
      (await subtle.generateKey(algorithm, false, ['sign', 'verify'].jsify()! as JSArray<JSString>).toDart) as _KeyPair;
  final jwk = (await subtle.exportKey('jwk', pair.publicKey).toDart)! as JSObject;
  final publicJwk = {
    for (final name in ['kty', 'crv', 'x', 'y']) name: (jwk.getProperty<JSString>(name.toJS)).toDart,
  }.jsify()! as JSObject;
  return _StoredKey(privateKey: pair.privateKey, publicJwk: publicJwk);
}

bool _isStoredKey(JSAny? value) {
  if (value == null || !value.isA<JSObject>()) return false;
  final key = value as _StoredKey;
  final privateKey = key.privateKey;
  final jwk = key.publicJwk;
  return privateKey != null &&
      privateKey.isA<web.CryptoKey>() &&
      (privateKey as web.CryptoKey).type == 'private' &&
      jwk != null &&
      jwk.getProperty<JSAny?>('x'.toJS).isA<JSString>() &&
      jwk.getProperty<JSAny?>('y'.toJS).isA<JSString>();
}

// The per-device backoff is keyed on this key, so it is kept across reloads. It stays non-extractable: IndexedDB stores
// the CryptoKey itself, never its bytes.
Future<_StoredKey> _loadKey() async {
  final factory = _keyStoreFactory();
  if (factory == null) return _generateKey();
  web.IDBDatabase? db;
  JSAny? stored;
  try {
    db = await _openKeyStore(factory);
    stored = await _settled<JSAny?>(db.transaction(_dbStore.toJS, 'readonly').objectStore(_dbStore).get(_dbKey.toJS));
  } catch (_) {
    db?.close();
    return _generateKey();
  }
  try {
    if (_isStoredKey(stored)) return stored as _StoredKey;
    final fresh = await _generateKey();
    try {
      final keys = db.transaction(_dbStore.toJS, 'readwrite').objectStore(_dbStore);
      // `add` rather than `put` when nothing is stored, so a tab that loses the race adopts the winner's key.
      await _settled<JSAny?>(stored == null ? keys.add(fresh, _dbKey.toJS) : keys.put(fresh, _dbKey.toJS));
      return fresh;
    } catch (_) {
      final winner = await _settled<JSAny?>(
        db.transaction(_dbStore.toJS, 'readonly').objectStore(_dbStore).get(_dbKey.toJS),
      ).catchError((Object _) => null);
      return _isStoredKey(winner) ? winner as _StoredKey : fresh;
    }
  } finally {
    db.close();
  }
}

class _WebCryptoKey implements DeviceKey {
  _WebCryptoKey(this._key, this.publicJwk);

  final web.CryptoKey _key;

  @override
  final Map<String, String> publicJwk;

  @override
  Future<Uint8List> sign(Uint8List data) async {
    final algorithm = {'name': 'ECDSA', 'hash': 'SHA-256'}.jsify()! as JSObject;
    final signature = await web.window.crypto.subtle.sign(algorithm, _key, data.toJS).toDart;
    return (signature! as JSArrayBuffer).toDart.asUint8List();
  }
}

/// A non-extractable WebCrypto key, kept in the browser's IndexedDB so a reload reuses it.
class WebCryptoKeys implements DeviceKeyProvider {
  Future<DeviceKey>? _key;

  @override
  Future<DeviceKey> getKey() => _key ??= _loadKey().then<DeviceKey>((stored) {
        final jwk = stored.publicJwk!;
        return _WebCryptoKey(stored.privateKey! as web.CryptoKey, {
          for (final name in ['kty', 'crv', 'x', 'y']) name: jwk.getProperty<JSString>(name.toJS).toDart,
        });
      }).catchError((Object e) {
        _key = null;
        throw e;
      });
}

const _recaptchaScript = 'https://www.google.com/recaptcha/enterprise.js?render=';

/// A check that never answers is given up on, so a mint is never stuck behind it.
const _checkTimeout = Duration(seconds: 30);

final _scripts = <String, ({web.HTMLScriptElement element, Future<void> done, bool Function() loaded})>{};

({web.HTMLScriptElement element, Future<void> done, bool Function() loaded}) _loadScript(String src) {
  final cached = _scripts[src];
  if (cached != null) return cached;
  final element = web.HTMLScriptElement()
    ..src = src
    ..async = true;
  var loaded = false;
  final done = Completer<void>();
  late final ({web.HTMLScriptElement element, Future<void> done, bool Function() loaded}) load;
  element.onload = ((web.Event _) {
    loaded = true;
    done.complete();
  }).toJS;
  element.onerror = ((web.Event _) {
    _forgetScript(src, load);
    done.completeError(StateError('Could not load $src'));
  }).toJS;
  load = (element: element, done: done.future, loaded: () => loaded);
  _scripts[src] = load;
  web.document.head!.appendChild(element);
  return load;
}

// A load that stalled is dropped, so the next attempt fetches the script again instead of waiting on it forever.
void _forgetScript(String src, ({web.HTMLScriptElement element, Future<void> done, bool Function() loaded}) load) {
  if (identical(_scripts[src], load)) _scripts.remove(src);
  load.element.remove();
}

/// reCAPTCHA Enterprise, run invisibly for a live key's mint.
Future<String> recaptchaToken(Map<String, dynamic> hint) async {
  final siteKey = hint['siteKey'] as String;
  final src = _recaptchaScript + Uri.encodeQueryComponent(siteKey);
  final script = _loadScript(src);
  try {
    return await script.done.then((_) {
      final enterprise =
          web.window.getProperty<JSObject?>('grecaptcha'.toJS)?.getProperty<JSObject?>('enterprise'.toJS);
      if (enterprise == null) throw StateError('reCAPTCHA Enterprise did not load');
      final token = Completer<String>();
      enterprise.callMethod<JSAny?>(
        'ready'.toJS,
        (() {
          final options = {'action': hint['action'] ?? ''}.jsify();
          enterprise
              .callMethod<JSPromise<JSString>>('execute'.toJS, siteKey.toJS, options)
              .toDart
              .then((value) => token.complete(value.toDart), onError: token.completeError);
        }).toJS,
      );
      return token.future;
    }).timeout(_checkTimeout);
  } catch (_) {
    if (!script.loaded()) _forgetScript(src, script);
    rethrow;
  }
}

/// The icon as declare sends it: a public https link as is, anything k-ID cannot reach (an asset, a local dev server)
/// fetched here and sent inline.
Future<String> readIcon(String iconUrl) async {
  if (iconUrl.startsWith('data:') || iconUrl.trim().isEmpty) return iconUrl;
  final url = Uri.base.resolve(iconUrl);
  final local =
      RegExp(r'^(localhost|.*\.localhost|.*\.local|.*\.test|\[.*\]|\d+\.\d+\.\d+\.\d+)$', caseSensitive: false);
  if (url.scheme == 'https' && !local.hasMatch(url.host)) return url.toString();
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw StateError('Could not read the app icon at $url (${response.statusCode}).');
  }
  final type = response.headers['content-type'] ?? 'application/octet-stream';
  return 'data:$type;base64,${base64Encode(response.bodyBytes)}';
}

/// The client for a page: its origin names it, its WebCrypto key binds its calls, and a live key runs the bot check.
ClientOptions platformClientOptions({required String publishableKey, required String baseUrl}) => ClientOptions(
      publishableKey: publishableKey,
      baseUrl: baseUrl,
      deviceKeys: WebCryptoKeys(),
      attestation: const ClientAttestation(platform: 'web'),
      botCheck: recaptchaToken,
      readIcon: readIcon,
      forbidden: ErrorMessage.unauthorizedOrigin,
    );

/// Each country's name in [locale], from the browser's `Intl.DisplayNames`; a code it cannot name is left out.
Future<Map<String, String>> countryNames(String locale, List<String> codes) async {
  try {
    final intl = web.window.getProperty<JSObject>('Intl'.toJS);
    final displayNames = intl.getProperty<JSFunction>('DisplayNames'.toJS);
    final names = displayNames.callAsConstructor<JSObject>(
      [locale].jsify(),
      {'type': 'region', 'fallback': 'none'}.jsify(),
    );
    return {
      for (final code in codes)
        if (names.callMethod<JSString?>('of'.toJS, code.toJS)?.toDart case final name?) code: name,
    };
  } catch (_) {
    return {};
  }
}
