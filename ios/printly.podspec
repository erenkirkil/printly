#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint printly.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'printly'
  s.version          = '0.1.0'
  s.summary          = 'Thermal printer SDK for Flutter.'
  s.description      = <<-DESC
Thermal printer SDK for Flutter. On iOS this pod provides BLE scanning,
connection, and ESC/POS printing via CoreBluetooth. Bluetooth Classic is
Android-only, because iOS requires MFi certification for Classic SPP
devices; the network (TCP/9100) transport is planned post-v1.
                       DESC
  s.homepage         = 'https://github.com/erenkirkil/printly'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Eren Kırkıl' => 'erenkirkil@gmail.com' }
  s.source           = { :path => '.' }
  # Sources live in the Swift Package Manager layout (ios/printly/Sources)
  # and are shared by both manifests: Package.swift for SPM consumers, this
  # podspec for CocoaPods consumers during the transition period.
  s.source_files = 'printly/Sources/printly/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'printly_privacy' => ['printly/Sources/printly/PrivacyInfo.xcprivacy']}
end
