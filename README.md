<img src="https://raw.github.com/andygeers/FirebaseParcelKit/master/ParcelKitLogo.png" width="89px" height="109px" />

# FirebaseParcelKit
FirebaseParcelKit integrates Core Data with [Google Firebase Realtime Database](https://firebase.google.com/docs/database/).
It is almost entirely based on Jonathan Younger's [ParcelKit](https://github.com/overcommitted/ParcelKit) which was for the excellent
but now-deprecated Dropbox Datastore.

Installation
------------
FirebaseParcelKit can be added to a project using [CocoaPods](https://github.com/cocoapods/cocoapods). We also distribute a framework build.

### Using CocoaPods [![Badge w/ Version](https://cocoapod-badges.herokuapp.com/v/ParcelKit/badge.png)](https://cocoadocs.org/docsets/ParcelKit)

```
// Podfile
pod 'FirebaseParcelKit', :git => "https://github.com/andygeers/FirebaseParcelKit"
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
Include FirebaseParcelKit in your application.

    #import <ParcelKit/ParcelKit.h>

Initialize an instance of the FirebaseParcelKit sync manager with the Core Data managed object context that
we should be used for listening for changes from and writing changes to - as well as the globally unique user ID from Firebase Auth:

    PKSyncManager *syncManager = [[PKSyncManager alloc] initWithManagedObjectContext:self.managedObjectContext userId:self.userId];

Associate the Core Data entity names with the corresponding Firebase database tables.

    [syncManager setTable:@"books" forEntityName:@"Book"];

Start observing changes from Core Data and Firebase.

    [syncManager startObserving];

Hold on to the sync manager reference.

    self.syncManager = syncManager;


Set up Core Data
----------------
<img src="https://raw.github.com/andygeers/ParcelKit/master/ParcelKitAttribute.png" align="right" width="725px" height="132px" />

ParcelKit requires two extra attribute inside your Core Data model.

* __syncID__ with the type __String__. The __Indexed__ property should also be checked.
* __isSynced__ with the type __Boolean__. The __Indexed__ property should also be checked.
* __remoteSyncTimestamp__ with the type __Int64__. The __Optional__ property should be checked and the default should be unchecked.

Make sure you add these attribute to each entity you wish to sync.

Alternative attribute names may be specifed by changing the syncAttributeName, isSyncedAttributeName and remoteTimestampAttributeName properties on the sync manager object.

Documentation
-------------
* [ParcelKit Reference](http://overcommitted.github.io/ParcelKit/) documentation

Example Application
-------------------
* [Toado](https://github.com/daikini/toado) - Simple task manager demonstrating the integration of Core Data and Dropbox using ParcelKit.


Requirements
------------
* iOS 7.0 or higher
* Google Firebase SDK 3.1.2 or higher
* Xcode 5 or higher

License
-------
[MIT](https://github.com/andygeers/ParcelKit/blob/master/LICENSE).
