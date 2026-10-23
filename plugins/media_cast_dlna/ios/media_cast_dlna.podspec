#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint media_cast_dlna.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'media_cast_dlna'
  s.version          = '0.2.0'
  s.summary          = 'A Flutter plugin for discovering and controlling DLNA/UPnP media devices'
  s.description      = <<-DESC
A Flutter plugin for discovering and controlling DLNA/UPnP media devices. Cast media to smart TVs and speakers with ease!
                       DESC
  s.homepage         = 'https://github.com/felnanuke2/media_cast_dlna'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'felnanuke2' => 'felnanuke@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'media_cast_dlna/Sources/media_cast_dlna/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 
    'DEFINES_MODULE' => 'YES', 
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES'
  }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'media_cast_dlna_privacy' => ['media_cast_dlna/Sources/media_cast_dlna/PrivacyInfo.xcprivacy']}
end
