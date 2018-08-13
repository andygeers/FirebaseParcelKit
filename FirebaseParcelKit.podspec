Pod::Spec.new do |s|
  s.name         = "FirebaseParcelKit"
  s.version      = "4.1.0"
  s.summary      = "FirebaseParcelKit integrates Core Data with Google Firebase."
  s.homepage     = "http://github.com/andygeers/FirebaseParcelKit"
  s.license      = 'MIT'
  s.author       = { "Andy Geers" => "andy.geers@googlemail.com" }
  s.source       = { :git => "https://github.com/andygeers/FirebaseParcelKit.git", :tag => s.version.to_s }
  s.platform     = :ios, '8.0'
  s.source_files = 'FirebaseParcelKit/*.{h,m}'
  s.frameworks   = 'CoreData', 'FirebaseDatabase'
  s.libraries    = 'c++', 'icucore'
  s.dependency 'Firebase'
  s.dependency 'Firebase/Database'
  s.requires_arc = true
  #s.xcconfig = { 'FRAMEWORK_SEARCH_PATHS' => '"${PODS_ROOT}/Firebase"' }

  s.pod_target_xcconfig = {
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) $(PODS_ROOT)/Firebase $(PODS_ROOT)/FirebaseDatabase/Frameworks'
  }

  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -ObjC'
  }
end
