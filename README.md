<img src="https://raw.github.com/andygeers/ParcelKit/master/ParcelKitLogo.png" width="89px" height="109px" />

# ParcelKit
ParcelKit integrates Core Data with [Couchbase Lite](http://www.couchbase.com/nosql-databases/couchbase-mobile).

Installation
------------
ParcelKit can be added to a project using [CocoaPods](https://github.com/cocoapods/cocoapods). We also distribute a framework build.

### Using CocoaPods [![Badge w/ Version](https://cocoapod-badges.herokuapp.com/v/ParcelKit/badge.png)](https://cocoadocs.org/docsets/ParcelKit)

```
// Podfile
pod 'ParcelKit', '~> 3.0'
```
and
```
pod install
```

### Framework
1. Open the ParcelKit.xcodeproj project
2. Select the “Framework” scheme
3. Build (⌘B) the Framework
4. Open the Products section in Xcode, right click “libParcelKit.a”, and select “Show in Finder”
5. Drag and drop the “ParcelKit.framework” folder into your iPhone/iPad project
6. Edit your build settings and add `-ObjC` to “Other Linker Flags”

Usage
-----
Include ParcelKit in your application.

    #import <ParcelKit/ParcelKit.h>

Initialize an instance of the ParcelKit sync manager with the Core Data managed object context and the Couchbase Lite database that
should be used for listening for changes from and writing changes to.

    PKSyncManager *syncManager = [[PKSyncManager alloc] initWithManagedObjectContext:self.managedObjectContext database:self.database];

Associate the Core Data entity names with the corresponding Couchbase Lite database tables.

    [syncManager setTable:@"books" forEntityName:@"Book"];

Start observing changes from Core Data and Couchbase Lite.

    [syncManager startObserving];

Hold on to the sync manager reference.

    self.syncManager = syncManager;


Set up Core Data
----------------
<img src="https://raw.github.com/andygeers/ParcelKit/master/ParcelKitAttribute.png" align="right" width="725px" height="132px" />

ParcelKit requires an extra attribute inside your Core Data model.

* __syncID__ with the type __String__. The __Indexed__ property should also be checked.

Make sure you add this attribute to each entity you wish to sync.

An alternative attribute name may be specifed by changing the syncAttributeName property on the sync manager object.

Documentation
-------------
* [ParcelKit Reference](http://overcommitted.github.io/ParcelKit/) documentation

Example Application
-------------------
* [Toado](https://github.com/daikini/toado) - Simple task manager demonstrating the integration of Core Data and Dropbox using ParcelKit.


Requirements
------------
* iOS 7.0 or higher
* Couchbase Lite SDK 1.2.0 or higher
* Xcode 5 or higher

License
-------
[MIT](https://github.com/andygeers/ParcelKit/blob/master/LICENSE).
