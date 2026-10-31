Pod::Spec.new do |s|
  s.name             = 'instant_barcode_scanner'
  s.version          = '0.1.0'
  s.summary          = 'Session-scoped barcode scanning for Flutter.'
  s.description      = <<-DESC
A session-scoped barcode scanner that keeps the camera warm between scans,
releases truthfully when idle, and returns raw barcode bytes alongside text.
                       DESC
  s.homepage         = 'https://github.com/schleunigst/instant_barcode_scanner'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Schleunigst' => 'https://github.com/schleunigst' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'GoogleMLKit/BarcodeScanning', '~> 9.0.0'
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'UIKit'
  s.platform = :ios, '15.5'
  s.static_framework = true

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version = '5.0'
end
