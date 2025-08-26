require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "DocumentScanner"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => '13.0' }
  s.swift_version = '5.9'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_INSTALL_OBJC_HEADER' => 'YES'
  }
  s.source       = { :git => "https://github.com/Preeternal/react-native-document-scanner-plugin.git", :tag => "#{s.version}" }
  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.private_header_files = "ios/**/*.h"


  install_modules_dependencies(s)
end
