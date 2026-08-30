#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint custom_mouse_cursor.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'custom_mouse_cursor'
  s.version          = '0.0.1'
  s.summary          = 'Flutter custom mouse cursor plugin.'
  s.description      = <<-DESC
Flutter custom mouse cursor plugin.
                       DESC
  s.homepage         = 'http://github.com/timmaffett/custom_mouse_cursor'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'HiveRight' => 'timmaffett@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
