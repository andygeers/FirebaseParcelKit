Pod::Spec.new do |s|
  s.name         = "ParcelKit"
  s.version      = "3.0.0"
  s.summary      = "ParcelKit integrates Core Data with Couchbase Lite."
  s.homepage     = "http://github.com/andygeers/ParcelKit"
  s.license      = 'MIT'
  s.author       = { "Andy Geers" => "andy.geers@googlemail.com" }
  s.source       = { :git => "https://github.com/andygeers/ParcelKit.git", :tag => s.version.to_s }
  s.platform     = :ios, '7.0'
  s.source_files = 'ParcelKit/*.{h,m}'
  s.frameworks   = 'CoreData', 'CouchbaseLite'
  s.requires_arc = true
  s.dependency 'couchbase-lite-ios', '~> 1.2.0'
  s.xcconfig = { 'FRAMEWORK_SEARCH_PATHS' => '"${PODS_ROOT}/couchbase-lite-ios/couchbase-lite-ios-1.2.0"' }
end
