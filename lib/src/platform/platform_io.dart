import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../client.dart';
import '../errors.dart';
import 'native.dart';

const _localHost = r'^(localhost|.*\.localhost|.*\.local|.*\.test|\[.*\]|\d+\.\d+\.\d+\.\d+)$';

/// The icon as declare sends it: a public https link as is, anything k-ID cannot reach (a bundled asset, a file) read
/// here and sent inline.
Future<String> readIcon(String iconUrl) async {
  if (iconUrl.startsWith('data:')) return iconUrl;
  final uri = Uri.tryParse(iconUrl);
  if (uri != null && uri.scheme == 'https' && !RegExp(_localHost, caseSensitive: false).hasMatch(uri.host)) {
    return iconUrl;
  }
  final List<int> bytes;
  if (uri != null && uri.scheme == 'file') {
    bytes = await File.fromUri(uri).readAsBytes();
  } else if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(uri)).close();
      if (response.statusCode != 200) throw HttpException('status ${response.statusCode}', uri: uri);
      bytes = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    } finally {
      client.close();
    }
  } else if (iconUrl.startsWith('/')) {
    bytes = await File(iconUrl).readAsBytes();
  } else {
    bytes = (await rootBundle.load(iconUrl)).buffer.asUint8List();
  }
  final type = bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 ? 'image/jpeg' : 'image/png';
  return 'data:$type;base64,${base64Encode(bytes)}';
}

/// The client for an app on iOS or Android: its hardware device key, its app id as `Kid-App-Id`, and attestation on a
/// live key.
ClientOptions platformClientOptions({required String publishableKey, required String baseUrl}) {
  final android = defaultTargetPlatform == TargetPlatform.android;
  return ClientOptions(
    publishableKey: publishableKey,
    baseUrl: baseUrl,
    deviceKeys: NativeDeviceKeys(),
    headers: nativeAppId().then((id) => id == null ? const <String, String>{} : {'Kid-App-Id': id}),
    attestation: nativeAttestation(android: android, liveKey: publishableKey.startsWith('kgp_live_')),
    readIcon: readIcon,
    platformAgeSignal: nativeAgeRange,
    forbidden: ErrorMessage.unauthorizedApp,
  );
}

/// Each country's name in [locale]; a code the platform cannot name is left out.
Future<Map<String, String>> countryNames(String locale, List<String> codes) => nativeCountryNames(locale, codes);
