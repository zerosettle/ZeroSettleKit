require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "RNZeroSettleKit"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  # iOS 17.0+ required for ZeroSettleKit's SwiftUI features
  s.platforms    = { :ios => "17.0" }
  s.source       = { :git => "https://github.com/ZeroSettle/react-native-zerosettle-kit.git", :tag => "#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift,cpp}"
  s.private_header_files = "ios/**/*.h"

  # Swift version
  s.swift_version = "5.9"

  # Required frameworks
  s.frameworks = "UIKit", "SwiftUI"

  # Depend on ZeroSettleKit CocoaPod
  s.dependency "ZeroSettleKit"

  install_modules_dependencies(s)
end
