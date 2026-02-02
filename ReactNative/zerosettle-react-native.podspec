require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "zerosettle-react-native"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "17.0" }
  s.source       = { :git => package["repository"]["url"], :tag => "#{s.version}" }

  # Include React Native bridge files AND ZeroSettle Swift sources directly
  # This avoids consumers needing to add a separate SwiftPM dependency
  s.source_files = [
    "ios/**/*.{h,m,mm,swift}",
    "../Sources/Core/**/*.swift",
    "../Sources/IAP/**/*.swift"
  ]

  # Exclude test files and resources that shouldn't be compiled
  s.exclude_files = [
    "../Sources/**/Tests/**/*",
    "../Sources/**/Resources/**/*"
  ]

  # Preserve folder structure for module organization
  s.preserve_paths = [
    "../Sources/Core/**/*",
    "../Sources/IAP/**/*"
  ]

  # Swift version
  s.swift_version = "5.9"

  # Frameworks
  s.frameworks = "UIKit", "SwiftUI", "StoreKit", "WebKit"

  # Dependencies
  s.dependency "React-Core"

  # ConfettiSwiftUI via CocoaPods (same library used by the Swift package)
  # Note: If this fails, you may need to add the pod repo manually or use SPM
  s.dependency "ConfettiSwiftUI"

  # Build settings
  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "SWIFT_COMPILATION_MODE" => "wholemodule",
    # Bridging header for Swift/ObjC interop
    "SWIFT_OBJC_BRIDGING_HEADER" => "$(PODS_TARGET_SRCROOT)/ios/ZeroSettleReactNative-Bridging-Header.h",
    # Header search paths for React
    "HEADER_SEARCH_PATHS" => "$(inherited) \"${PODS_ROOT}/Headers/Public/React-Core\""
  }

  # User target settings
  s.user_target_xcconfig = {
    "SWIFT_VERSION" => "5.9"
  }
end
