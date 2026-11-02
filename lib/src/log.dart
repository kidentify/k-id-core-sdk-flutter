import 'dart:developer' as developer;

/// Where the SDK's console output goes; tests replace it.
class KidLog {
  static void Function(String message) warn = (message) => developer.log(message, name: 'k-ID', level: 900);
  static void Function(String message, [Object? detail]) error =
      (message, [detail]) => developer.log(message, name: 'k-ID', level: 1000, error: detail);
}
