import CryptoKit
import DeviceCheck
import Flutter
import Foundation
import UIKit

#if canImport(DeclaredAgeRange)
  import DeclaredAgeRange
#endif

/// The native half of k_id_core: the device key, App Attest, Declared Age Range and the app id.
public final class KidCorePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.k-id.core/flutter", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(KidCorePlugin(), channel: channel)
  }

  // The iOS SDK's names, so an app that moves between the SDKs keeps its keys.
  private let appAttestKeyIdName = "com.k-id.core.appAttestKeyId"

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "appId":
      result(Bundle.main.bundleIdentifier)
    case "publicJwk":
      run(result) { try DeviceKeys.shared.key().publicJWK }
    case "sign":
      guard let data = args["data"] as? FlutterStandardTypedData else { return result(Self.invalid("data")) }
      run(result) { FlutterStandardTypedData(bytes: try DeviceKeys.shared.key().sign(data.data)) }
    case "isAppAttestSupported":
      result(DCAppAttestService.shared.isSupported)
    case "loadAppAttestKeyId":
      result(UserDefaults.standard.string(forKey: appAttestKeyIdName))
    case "saveAppAttestKeyId":
      UserDefaults.standard.set(args["keyId"] as? String, forKey: appAttestKeyIdName)
      result(nil)
    case "generateAppAttestKey":
      Task { await Self.reply(result) { try await DCAppAttestService.shared.generateKey() } }
    case "attestAppAttestKey", "generateAppAttestAssertion":
      guard let keyId = args["keyId"] as? String, let hash = args["clientDataHash"] as? FlutterStandardTypedData
      else { return result(Self.invalid("keyId and clientDataHash")) }
      let attest = call.method == "attestAppAttestKey"
      Task {
        await Self.reply(result) {
          let data =
            attest
            ? try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: hash.data)
            : try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: hash.data)
          return FlutterStandardTypedData(bytes: data)
        }
      }
    case "countryNames":
      let names = Locale(identifier: args["locale"] as? String ?? "en")
      var out: [String: String] = [:]
      for code in args["codes"] as? [String] ?? [] {
        if let name = names.localizedString(forRegionCode: code), name != code { out[code] = name }
      }
      result(out)
    case "isAgeRangeSupported":
      if #available(iOS 26, *) { result(true) } else { result(false) }
    case "requestAgeRange":
      let gates = args["ageGates"] as? [Int] ?? []
      Task { @MainActor in result(await Self.requestAgeRange(gates)) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func run(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Any) {
    DispatchQueue.global(qos: .userInitiated).async {
      let reply: Any
      do { reply = try work() } catch { reply = FlutterError(code: "failed", message: "\(error)", details: nil) }
      DispatchQueue.main.async { result(reply) }
    }
  }

  private static func reply(_ result: @escaping FlutterResult, _ work: () async throws -> Any) async {
    let reply: Any
    do { reply = try await work() } catch { reply = FlutterError(code: "failed", message: "\(error)", details: nil) }
    await MainActor.run { result(reply) }
  }

  private static func invalid(_ what: String) -> FlutterError {
    FlutterError(code: "invalid", message: "\(what) is required", details: nil)
  }

  // Asked over the top view controller. It needs the app's com.apple.developer.declared-age-range entitlement;
  // without it the request throws and no range is shared.
  @MainActor
  private static func requestAgeRange(_ ageGates: [Int]) async -> [String: Any]? {
    #if canImport(DeclaredAgeRange)
      if #available(iOS 26, *) {
        guard let first = ageGates.first, let presenter = topViewController(),
          case .sharing(let range)? = try? await AgeRangeService.shared.requestAgeRange(
            ageGates: first, ageGates.dropFirst().first, ageGates.dropFirst(2).first, in: presenter)
        else { return nil }
        var signal: [String: Any] = [
          "name": "apple-ios",
          "ageLow": range.lowerBound ?? 0,
          "ageHigh": range.upperBound ?? -1,
        ]
        // The case names are the server's declaration types; describing them avoids switching over the deprecated ones.
        if let declaration = range.ageRangeDeclaration { signal["declarationType"] = String(describing: declaration) }
        return signal
      }
    #endif
    return nil
  }

  @MainActor
  private static func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}

private protocol DeviceKey {
  var publicJWK: [String: String] { get }
  /// Returns the raw 64-byte `r || s` signature JWS expects.
  func sign(_ data: Data) throws -> Data
}

private func jwk(_ publicKey: P256.Signing.PublicKey) -> [String: String] {
  // x963 is 0x04 || X || Y.
  let point = publicKey.x963Representation
  return [
    "kty": "EC",
    "crv": "P-256",
    "x": base64URL(point.dropFirst().prefix(32)),
    "y": base64URL(point.suffix(32)),
  ]
}

private func base64URL(_ data: some DataProtocol) -> String {
  Data(data).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private struct SecureEnclaveDeviceKey: DeviceKey {
  let privateKey: SecureEnclave.P256.Signing.PrivateKey
  var publicJWK: [String: String] { jwk(privateKey.publicKey) }
  func sign(_ data: Data) throws -> Data { try privateKey.signature(for: data).rawRepresentation }
}

private struct SoftwareDeviceKey: DeviceKey {
  let privateKey: P256.Signing.PrivateKey
  var publicJWK: [String: String] { jwk(privateKey.publicKey) }
  func sign(_ data: Data) throws -> Data { try privateKey.signature(for: data).rawRepresentation }
}

private struct KeychainError: Error {
  let status: OSStatus
}

/// The install's Secure Enclave key, its handle kept in the Keychain and never migrated: on another device the handle
/// would not open the key anyway. A simulator without a Secure Enclave gets a key for this launch.
private final class DeviceKeys: @unchecked Sendable {
  static let shared = DeviceKeys()

  private let lock = NSLock()
  private var cached: DeviceKey?
  private let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.k-id.core.deviceKey",
    kSecAttrAccount as String: "dpop",
  ]

  func key() throws -> DeviceKey {
    lock.lock()
    defer { lock.unlock() }
    if let cached { return cached }
    let key = try load()
    cached = key
    return key
  }

  private func load() throws -> DeviceKey {
    guard SecureEnclave.isAvailable else { return SoftwareDeviceKey(privateKey: P256.Signing.PrivateKey()) }
    let handle: Data?
    do {
      handle = try loadHandle()
    } catch {
      // An unreadable Keychain (before first unlock) gets a key for this launch; the stored one is kept.
      return SecureEnclaveDeviceKey(privateKey: try SecureEnclave.P256.Signing.PrivateKey())
    }
    // A handle that no longer opens a key, such as one restored onto another device, is replaced.
    if let handle, let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle) {
      return SecureEnclaveDeviceKey(privateKey: key)
    }
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    try? saveHandle(key.dataRepresentation)
    return SecureEnclaveDeviceKey(privateKey: key)
  }

  private func loadHandle() throws -> Data? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return item as? Data
  }

  private func saveHandle(_ handle: Data) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: handle,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      let added = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
      guard added == errSecSuccess else { throw KeychainError(status: added) }
      return
    }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }
}
