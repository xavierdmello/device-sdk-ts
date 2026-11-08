require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "device-transport-kit-react-native-hid"
  s.version      = package["version"]
  s.summary      = "USB transport for the Ledger Device Management Kit (CCID via CryptoTokenKit on iOS)"
  s.homepage     = "https://github.com/LedgerHQ/device-sdk-ts"
  s.license      = package["license"]
  s.authors      = "Ledger"
  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/LedgerHQ/device-sdk-ts.git", :tag => "#{s.version}" }
  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.frameworks   = "CryptoTokenKit"
  s.swift_version = "5.0"

  install_modules_dependencies(s)
end
