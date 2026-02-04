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

  # Only the React Native bridge files
  s.source_files = "ios/**/*.{h,m,mm,swift}"

  # Swift version
  s.swift_version = "5.9"

  # Frameworks
  s.frameworks = "UIKit", "SwiftUI"

  # Dependencies
  s.dependency "React-Core"
  s.dependency "ZeroSettleKit", "~> 1.0"

  # Build settings
  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "SWIFT_COMPILATION_MODE" => "wholemodule"
  }
end
