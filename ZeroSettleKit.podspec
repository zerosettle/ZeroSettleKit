Pod::Spec.new do |s|
  s.name             = 'ZeroSettleKit'
  s.version          = '1.6.0'
  s.summary          = 'Merchant of Record SDK for iOS — web checkout, entitlements, and compliance.'
  s.description      = <<-DESC
    ZeroSettleKit lets iOS developers process payments via web checkout
    while ZeroSettle handles sales tax, VAT, compliance, and liability
    as the Merchant of Record.
  DESC

  s.homepage         = 'https://github.com/zerosettle/ZeroSettleKit'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'ZeroSettle, Inc.' => 'ryan@zerosettle.io' }
  s.source           = { :git => 'https://github.com/zerosettle/ZeroSettleKit.git', :tag => s.version.to_s }

  s.ios.deployment_target = '17.0'
  s.swift_version = '5.9'

  # Compile both targets into a single CocoaPods module.
  # The #if canImport(ZeroSettleCore) guards in source skip
  # the inter-module imports since everything is in one module.
  s.source_files = [
    'Sources/ZeroSettleCore/**/*.swift',
    'Sources/ZeroSettleKit/**/*.swift'
  ]

  # Apple requires the privacy manifest at the root of a bundle. SPM gets this
  # from the `resources:` declaration in Package.swift; CocoaPods needs its own,
  # or pod consumers — which today means every Flutter adopter — install 1.6.0
  # without the manifest and are back to declaring our UserDefaults use on our
  # behalf.
  s.resource_bundles = {
    'ZeroSettleKit' => ['Sources/ZeroSettleKit/PrivacyInfo.xcprivacy']
  }

  s.frameworks = 'Foundation', 'UIKit', 'SwiftUI', 'StoreKit',
                 'WebKit', 'SafariServices', 'Combine', 'PassKit'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
