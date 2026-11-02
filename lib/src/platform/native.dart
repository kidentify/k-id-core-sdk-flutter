import 'dart:convert';

import 'package:flutter/services.dart';

import '../client_trust.dart';
import '../log.dart';
import '../models.dart';

const channel = MethodChannel('com.k-id.core/flutter');

class _ChannelKey implements DeviceKey {
  _ChannelKey(this.publicJwk);

  @override
  final Map<String, String> publicJwk;

  @override
  Future<Uint8List> sign(Uint8List data) async => (await channel.invokeMethod<Uint8List>('sign', {'data': data}))!;
}

/// The install's hardware key: the Secure Enclave on iOS, the Android Keystore on Android.
class NativeDeviceKeys implements DeviceKeyProvider {
  Future<DeviceKey>? _key;

  @override
  Future<DeviceKey> getKey() => _key ??= channel
          .invokeMapMethod<String, String>('publicJwk')
          .then<DeviceKey>((jwk) => _ChannelKey(jwk!))
          .catchError((Object e) {
        _key = null;
        throw e;
      });
}

/// The bundle id on iOS, the package name on Android.
Future<String?> nativeAppId() async {
  try {
    return await channel.invokeMethod<String>('appId');
  } on MissingPluginException {
    return null;
  }
}

ClientAttestation _appAttest() => ClientAttestation(
      platform: 'ios',
      evidence: (clientDataHash) async {
        if (await channel.invokeMethod<bool>('isAppAttestSupported') != true) return null;
        try {
          final keyId = await channel.invokeMethod<String>('loadAppAttestKeyId');
          if (keyId != null) {
            final assertion = await channel.invokeMethod<Uint8List>(
              'generateAppAttestAssertion',
              {'keyId': keyId, 'clientDataHash': clientDataHash},
            );
            return {'platform': 'ios', 'keyId': keyId, 'assertion': base64Encode(assertion!)};
          }
          final fresh = (await channel.invokeMethod<String>('generateAppAttestKey'))!;
          final attestation = await channel.invokeMethod<Uint8List>(
            'attestAppAttestKey',
            {'keyId': fresh, 'clientDataHash': clientDataHash},
          );
          return {'platform': 'ios', 'keyId': fresh, 'attestation': base64Encode(attestation!)};
        } catch (_) {
          // A key the OS no longer honours is dropped; the next mint attests a new one.
          await channel.invokeMethod<void>('saveAppAttestKeyId', {'keyId': null});
          return null;
        }
      },
      minted: (sent, verified) {
        if (verified) {
          if (sent['attestation'] != null) channel.invokeMethod<void>('saveAppAttestKeyId', {'keyId': sent['keyId']});
          return;
        }
        // A key the server didn't accept is dropped, so the next mint attests a fresh one.
        if (sent['keyId'] != null) channel.invokeMethod<void>('saveAppAttestKeyId', {'keyId': null});
        KidLog.warn(
            'App Attest failed. It works only in App Store and TestFlight builds; use a test key while developing.');
      },
    );

ClientAttestation _keyAttestation() => ClientAttestation(
      platform: 'android',
      evidence: (clientDataHash) async {
        try {
          final chain = await channel.invokeListMethod<Uint8List>('keyAttestationChain', {'challenge': clientDataHash});
          return chain == null ? null : {'platform': 'android', 'attestationChain': chain.map(base64Encode).toList()};
        } catch (_) {
          return null;
        }
      },
      minted: (sent, verified) {
        if (verified) return;
        KidLog.warn(
          'Key Attestation failed. It needs a release build signed with a certificate registered in Kai, on a device '
          'with a locked bootloader; use a test key while developing.',
        );
      },
    );

/// The mint's platform, with the device's evidence on a live key; a test key mints basic trust whatever it sends.
ClientAttestation nativeAttestation({required bool android, required bool liveKey}) {
  if (!liveKey) return ClientAttestation(platform: android ? 'android' : 'ios');
  return android ? _keyAttestation() : _appAttest();
}

Future<bool>? _ageRangeSupported;

/// Apple's Declared Age Range on iOS 26 and later, or Google Play Age Signals; null where the platform has none. A
/// decline, or a failure, falls back to the age step.
Future<PlatformAgeSignal?> nativeAgeRange(List<int> ageGates) async {
  try {
    final supported = _ageRangeSupported ??= channel.invokeMethod<bool>('isAgeRangeSupported').then((s) => s == true);
    if (!await supported) return null;
    final signal = await channel.invokeMapMethod<String, Object?>('requestAgeRange', {'ageGates': ageGates});
    return signal == null ? null : PlatformAgeSignal.fromJson(signal);
  } catch (_) {
    return null;
  }
}

/// Each country's name in [locale], from the platform; a code it cannot name is left out.
Future<Map<String, String>> nativeCountryNames(String locale, List<String> codes) async {
  try {
    return await channel.invokeMapMethod<String, String>('countryNames', {'locale': locale, 'codes': codes}) ?? {};
  } catch (_) {
    return {};
  }
}
