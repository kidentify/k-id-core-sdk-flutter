Pod::Spec.new do |s|
  s.name             = 'k_id_core'
  s.version          = '1.0.0'
  s.summary          = 'The k-ID SDK for Flutter apps.'
  s.homepage         = 'https://github.com/kidentify/k-id-core-sdk-flutter'
  s.author           = { 'k-ID' => 'support@k-id.com' }
  s.license          = { :file => '../LICENSE' }
  s.source           = { :path => '.' }
  s.source_files     = 'k_id_core/Sources/k_id_core/**/*.swift'
  s.resource_bundles = { 'k_id_core_privacy' => ['k_id_core/Sources/k_id_core/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.9'
end
