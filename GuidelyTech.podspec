Pod::Spec.new do |s|
  s.name             = 'GuidelyTech'
  s.module_name      = 'Guidely'
  s.version          = '0.2.0'
  s.summary          = 'Guidely in-app guides for iOS: tours, tooltips, checklists, surveys and a resource center.'
  s.description      = <<-DESC
    The native iOS SDK for Guidely (guidelytech.com). Renders guides published from the Guidely
    dashboard (modals, tooltips, spotlights, hotspots, banners, slideouts, checklists, NPS/CSAT
    surveys and a resource center) in a passthrough overlay window, with targeting, frequency
    rules and analytics identical to the web SDK, plus feature flags and experiments. SwiftUI and UIKit.
  DESC
  s.homepage         = 'https://guidelytech.com'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Guidely' => 'support@guidelytech.com' }
  s.source           = { :git => 'https://github.com/GuidelyTech/guidely-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.9', '5.10', '6.0']

  # GuidelyCore (Foundation-only engine) and the UIKit/SwiftUI layer compile into one `Guidely` module.
  s.source_files     = 'Sources/GuidelyCore/**/*.swift', 'Sources/Guidely/**/*.swift'
  s.frameworks       = 'Foundation', 'UIKit', 'SwiftUI'
end
