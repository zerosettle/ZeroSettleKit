Pod::Spec.new do |s|
  s.name             = 'ZeroSettleKit'
  s.version          = '1.0.0'
  s.summary          = 'ZeroSettle SDK for iOS - In-App Purchase solutions'
  s.description      = <<-DESC
    ZeroSettleKit provides the ZeroSettleIAP module for Merchant of Record web checkout.
    
    For the full ZeroSettleEscrow module (blockchain escrow functionality), 
    please use Swift Package Manager instead, as it requires dependencies
    (Privy, Solana, MetaMask, Coinbase) that are only available via SPM.
  DESC

  s.homepage         = 'https://github.com/ZeroSettle/ZeroSettleKit'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'ZeroSettle' => 'gabe@zerosettle.com' }
  s.source           = { :git => 'https://github.com/ZeroSettle/ZeroSettleKit.git', :tag => s.version.to_s }

  s.ios.deployment_target = '17.0'
  s.swift_version = '5.9'

  # Source files - include both Core and IAP
  # CocoaPods compiles everything into a single module, so no inter-module imports needed
  s.source_files = [
    'Sources/Core/**/*.swift',
    'Sources/IAP/**/*.swift'
  ]

  # System frameworks
  s.frameworks = 'Foundation', 'UIKit', 'SwiftUI', 'StoreKit', 'WebKit'

  # Build settings
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    # Define flag to detect CocoaPods build (no space after -D)
    'OTHER_SWIFT_FLAGS' => '-DCOCOAPODS'
  }
end
