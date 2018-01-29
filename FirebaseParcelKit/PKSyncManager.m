//
//  PKSyncManager.m
//  ParcelKit
//
//  Copyright (c) 2013 Overcommitted, LLC. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "PKSyncManager.h"
#import "FIRManagedObjectToFirebase.h"
#import "FIRFirebaseToManagedObject.h"
#import "ParcelKitSyncedObject.h"
#include <time.h>
#include <xlocale.h>
#import "NSNull+PKNull.h"

NSString * const PKDefaultSyncAttributeName = @"syncID";
NSString * const PKDefaultIsSyncedAttributeName = @"isSynced";
NSString * const PKDefaultLastDeviceIdAttributeName = @"lastDeviceId";
NSString * const PKDefaultRemoteTimestampAttributeName = @"remoteSyncTimestamp";
NSString * const PKSyncManagerFirebaseStatusDidChangeNotification = @"PKSyncManagerFirebaseStatusDidChange";
NSString * const PKSyncManagerFirebaseStatusKey = @"status";
NSString * const PKSyncManagerFirebaseIncomingChangesNotification = @"PKSyncManagerFirebaseIncomingChanges";
NSString * const PKSyncManagerFirebaseIncomingChangesKey = @"changes";
NSString * const PKSyncManagerFirebaseDeletedAtKey = @"pk__deletedAt_";
NSString * const PKUpdateManagedObjectKey = @"object";
NSString * const PKUpdateDocumentKey = @"document";

@interface PKSyncManager ()
@property (nonatomic, strong) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (nonatomic, strong, readwrite) NSManagedObjectContext *managedObjectContext;
@property (nonatomic, strong, readwrite) FIRDatabaseReference *database;
@property (nonatomic, strong) NSMutableDictionary *tablesKeyedByEntityName;
@property (nonatomic, strong) NSMutableSet *prioritiesSetOnTables;
@property (nonatomic, strong) NSArray *sortedEntityNames;
@property (nonatomic) BOOL observing;
@property (nonatomic, strong) id observer;
@property (nonatomic, strong) NSArray* databaseHandles;
@property (nonatomic, strong) NSTimer* pullTimer;
@property (nonatomic) BOOL hasCompletedInitialPull;
@property (atomic, strong) NSManagedObjectContext* childManagedObjectContext;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation PKSyncStatus
@end

@implementation PKSyncManager

+ (NSString *)syncID
{
    CFUUIDRef uuidRef = CFUUIDCreate(NULL);
    NSString *uuid = (NSString *)CFBridgingRelease(CFUUIDCreateString(NULL, uuidRef));
    return [uuid stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

- (instancetype)init
{
    self = [super init];
    if (self) {        
        _tablesKeyedByEntityName = [[NSMutableDictionary alloc] init];
        _syncAttributeName = PKDefaultSyncAttributeName;
        _isSyncedAttributeName = PKDefaultIsSyncedAttributeName;
        _lastDeviceIdAttributeName = PKDefaultLastDeviceIdAttributeName;
        _remoteTimestampAttributeName = PKDefaultRemoteTimestampAttributeName;
        _localDeviceId = [self generateLocalDeviceId];
        
        _currentSyncStatus = [[PKSyncStatus alloc] init];
        
        [self resetPrioritiesSetOnTables];
    }
    return self;
}

- (instancetype)initWithManagedObjectContext:(NSManagedObjectContext *)managedObjectContext userId:(NSString*)userId queue:(dispatch_queue_t)queue
{
    self = [self init];
    if (self) {
        _queue = queue;
        _managedObjectContext = managedObjectContext;
        _databaseRoot = [[FIRDatabase database] reference];
        self.userId = userId;
        
        dispatch_async(self.queue, ^() {
            [self initialiseChildObjectContext];
        });
    }
    return self;
}

- (void)resetPrioritiesSetOnTables {
    NSMutableSet* tables = [[NSMutableSet alloc] init];
    self.prioritiesSetOnTables = tables;
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator) return _persistentStoreCoordinator;
    
    if ([self.managedObjectContext persistentStoreCoordinator]) {
        _persistentStoreCoordinator = [self.managedObjectContext persistentStoreCoordinator];
    } else if ([self.managedObjectContext parentContext]) {
        if ([[self.managedObjectContext parentContext] persistentStoreCoordinator]) {
            _persistentStoreCoordinator = [[self.managedObjectContext parentContext] persistentStoreCoordinator];
        }
    }
    
    return _persistentStoreCoordinator;
}

- (NSString*)generateLocalDeviceId {
    // Generate a string that is unique to this device
    // It actually doesn't need to be the same across sessions, so just generate a random string
    return [[NSUUID UUID] UUIDString];
}

#pragma mark - Entity and Table map

- (NSArray*)tableDependencies:(NSString*)tableName from:(NSSet*)tableNames {
    
    NSMutableArray* dependencies = [NSMutableArray arrayWithCapacity:tableNames.count];
    
    NSEntityDescription* entity = [NSEntityDescription entityForName:tableName inManagedObjectContext:self.managedObjectContext];
    NSDictionary *propertiesByName = [entity propertiesByName];
    [propertiesByName enumerateKeysAndObjectsUsingBlock:^(NSString *propertyName, NSPropertyDescription *propertyDescription, BOOL *stop) {
        if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
            NSRelationshipDescription *relationshipDescription = (NSRelationshipDescription *)propertyDescription;
            NSRelationshipDescription *inverse = [relationshipDescription inverseRelationship];
            
            // Feeds have subjects, subjects don't have feeds
            
            // If it's a one-to-many relationship, leave all the relationship business to the "one" side of the equation
            BOOL isToMany = [relationshipDescription isToMany];
            BOOL isManyToMany = isToMany && [inverse isToMany];
            BOOL isOneToOne = !isToMany && ![inverse isToMany];
            NSString* linkedTableName = relationshipDescription.destinationEntity.name;
            
            BOOL isDependency = NO;
            if (isManyToMany) {
                isDependency = YES;
            } else if (isOneToOne) {
                // Only include the alphabetically higher table as the dependency
                isDependency = [linkedTableName compare:tableName] == NSOrderedDescending;
            } else if (!isToMany) {
                isDependency = YES;
            }
            
            if (isDependency) {
                if ([tableNames containsObject:linkedTableName]) {
                    [dependencies addObject:linkedTableName];
                }
            }
        }
    }];
    
    return dependencies;
}

- (void)sortTableNames {
    // Start with a set of ALL table names
    NSMutableSet* remainingTableNames = [[NSMutableSet alloc] initWithCapacity:self.tablesKeyedByEntityName.count];
    for (NSString* tableName in self.tablesKeyedByEntityName.allKeys) {
        [remainingTableNames addObject:tableName];
    }
    
    NSMutableArray* sortedTableNames = [[NSMutableArray alloc] initWithCapacity:self.tablesKeyedByEntityName.count];
    
    for (NSInteger times = 1; times <= self.tablesKeyedByEntityName.count; times ++) {
        // Find any tables that have no remaining dependencies
        NSArray* tableNamesArray = [remainingTableNames allObjects];
        for (NSString* tableName in tableNamesArray) {
            NSArray* tableDependencies = [self tableDependencies:tableName from:remainingTableNames];
            if ((tableDependencies.count == 0) || (times == self.tablesKeyedByEntityName.count)) {
                // We can use this table now
                [sortedTableNames addObject:tableName];
                [remainingTableNames removeObject:tableName];
            }
        }
        
        if (remainingTableNames.count == 0) {
            // Nothing left to do
            break;
        }
    }
    
    self.sortedEntityNames = sortedTableNames;
}

- (void)setTablesForEntityNamesWithDictionary:(NSDictionary *)keyedTables
{
    [self resetPrioritiesSetOnTables];
    
    for (NSString *entityName in [self entityNames]) {
        [self removeTableForEntityName:entityName];
    }

    __weak typeof(self) weakSelf = self;
    [keyedTables enumerateKeysAndObjectsUsingBlock:^(NSString *entityName, NSString *tableID, BOOL *stop) {
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        [strongSelf setTable:tableID forEntityName:entityName];
    }];
    
    [self sortTableNames];
}

- (void)setTable:(NSString *)tableID forEntityName:(NSString *)entityName
{
    NSEntityDescription *entity = [NSEntityDescription entityForName:entityName inManagedObjectContext:self.managedObjectContext];
    NSAttributeDescription *attributeDescription = [[entity attributesByName] objectForKey:self.syncAttributeName];
    NSAssert([attributeDescription attributeType] == NSStringAttributeType, @"Entity “%@” must contain a string attribute named “%@”", entityName, self.syncAttributeName);
    [self.tablesKeyedByEntityName setObject:tableID forKey:entityName];
}

- (void)removeTableForEntityName:(NSString *)entityName
{
    [self.tablesKeyedByEntityName removeObjectForKey:entityName];
}

- (NSDictionary *)tablesByEntityName
{
    return [[NSDictionary alloc] initWithDictionary:self.tablesKeyedByEntityName];
}

- (NSArray *)tableIDs
{
    return [self.tablesKeyedByEntityName allValues];
}

- (NSArray *)entityNames
{
    return [self.tablesKeyedByEntityName allKeys];
}

- (NSString *)tableForEntityName:(NSString *)entityName
{
    return [self.tablesKeyedByEntityName objectForKey:entityName];
}

- (NSString*)entityNameForTable:(NSString*)tableName {
    return [[self.tablesKeyedByEntityName allKeysForObject:tableName] firstObject];
}

#pragma mark - Observing methods
- (BOOL)isObserving
{
    return self.observing;
}

- (void)postSyncStatusNotification {
    [[NSNotificationCenter defaultCenter] postNotificationName:PKSyncManagerFirebaseStatusDidChangeNotification object:self userInfo:@{ PKSyncManagerFirebaseStatusKey: self.currentSyncStatus }];
}

- (void)pullTimerAction:(NSTimer *)timer {
    if (!self.hasCompletedInitialPull) {
        [self concludePullingRemoteChanges];
    }
    
    self.currentSyncStatus.downloading = NO;
    [self postSyncStatusNotification];
}

- (void)finalisePull {
    if ((self.childManagedObjectContext != nil) && ([self.childManagedObjectContext hasChanges])) {
        dispatch_async(self.queue, ^{
            NSMutableSet *changedObjects = [[NSMutableSet alloc] init];
            [changedObjects unionSet:[self.childManagedObjectContext insertedObjects]];
            [changedObjects unionSet:[self.childManagedObjectContext updatedObjects]];
            NSDictionary* changes = @{ PKSyncManagerFirebaseIncomingChangesKey: changedObjects };
            
            [self mergeChildObjectContext:self.childManagedObjectContext];
            
            // Fire a change notification
            [[NSNotificationCenter defaultCenter] postNotificationName:PKSyncManagerFirebaseIncomingChangesNotification object:self userInfo:changes];
        });
    }
}

- (void)startPullTimer {
    if (self.pullTimer != nil) {
        [self.pullTimer invalidate];
    }
    
    self.currentSyncStatus.downloading = YES;
    [self postSyncStatusNotification];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Start a timer
        self.pullTimer = [NSTimer scheduledTimerWithTimeInterval:9.0f target:self selector:@selector(pullTimerAction:) userInfo:nil repeats:NO];
    });
}

- (void)resetPullTimer {
    if (self.pullTimer != nil) {
        // Stop any previous timer
        [self.pullTimer invalidate];
        self.pullTimer = nil;
    }
    
    // Start counting again
    [self startPullTimer];
}

- (void)concludePullingRemoteChanges {
    // No need to run this next time a pull completes
    self.hasCompletedInitialPull = YES;
    
    // Send our global app settings to the cloud:
    //updateAppSettings();
    // Send all our unsynced objects to the cloud:
    [self pushAllUnsyncedObjects];
}

- (void)pushAllUnsyncedObjects {
    FIRDatabaseReference* userRoot = [[self.databaseRoot child:@"users"] child:self.userId];
    
    if (!self.currentSyncStatus.uploading) {
        // Start the counters from zero
        self.currentSyncStatus.totalRecordsToUpload = 0;
        self.currentSyncStatus.uploadedRecords = 0;
    }
    
    self.currentSyncStatus.uploading = YES;
    [self postSyncStatusNotification];
    
    NSArray *entityNames = self.sortedEntityNames;
    for (NSString *entityName in entityNames) {
        NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:entityName];
        [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"%K == 0", self.isSyncedAttributeName]];
        [fetchRequest setFetchBatchSize:25];
        
        NSError* error = nil;
        NSArray *objects = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];
        if (objects) {
            DEBUG_LOG(@"Pushing %d unsynced object(s) for %@", (int)objects.count, entityName);
            if (objects.count > 0) {
                self.currentSyncStatus.totalRecordsToUpload += objects.count;
                
                dispatch_async(self.queue, ^{
                    for (NSManagedObject *managedObject in objects) {
                        NSNumber* isSynced = [managedObject valueForKey:self.isSyncedAttributeName];
                        if (![isSynced boolValue]) {
                            
                            if ((self.delegate != nil) && ([self.delegate respondsToSelector:@selector(isRecordSyncable:)])) {
                                if (![self.delegate isRecordSyncable:managedObject]) {
                                    // Skip this object
                                    [self progressUploadedObject];
                                    continue;
                                }
                            }
                            
                            // Push this object to the cloud
                            [self updateFirebaseWithManagedObject:managedObject userRoot:userRoot];
                        } else {
                            [self progressUploadedObject];
                        }
                    }

                    // Mark these objects as synced
                    [self markObjectsAsSynced:objects];
                    
                    DEBUG_LOG(@"Finished pushing unsynced objects for %@", entityName);
                });
            }            
        }
    }
    
    if (self.currentSyncStatus.totalRecordsToUpload == 0) {
        self.currentSyncStatus.uploading = NO;
        self.currentSyncStatus.totalRecordsToUpload = 0;
        self.currentSyncStatus.uploadedRecords = 0;
        [self postSyncStatusNotification];
    }
}

- (void)addHandle:(FIRDatabaseHandle)handle {
    if (self.databaseHandles == nil) {
        self.databaseHandles = [NSArray arrayWithObject:[NSNumber numberWithLong:handle]];
    } else {
        self.databaseHandles = [self.databaseHandles arrayByAddingObject:[NSNumber numberWithLong:handle]];
    }
}

- (void)startObserving
{
    if ([self isObserving]) return;
    self.observing = YES;
    
    __weak typeof(self) weakSelf = self;
    
    // Start listening to changes at the root of the database
    FIRDatabaseReference* userRoot = [[self.databaseRoot child:@"users"] child:self.userId];
    
    // I kind of want to start a timer that gets reset any time a change is detected,
    // and if no changes are received for X seconds we presume that we have everything
    [self startPullTimer];
    
    DEBUG_LOG(@"Initialise pull from user root %@ (local device ID %@)", [userRoot key], self.localDeviceId);
    
    // We need to observe each database table for changes independently - otherwise we'll be sent the entire database any time any tables changes
    for (NSString* entityName in self.sortedEntityNames) {
        NSString* tableName = [self tableForEntityName:entityName];
        FIRDatabaseReference* table = [userRoot child:tableName];
        if (table != nil) {
            DEBUG_LOG(@"Beginning observations of entityName %@ table name %@", entityName, tableName);
            
            [self addHandle:[table observeEventType:FIRDataEventTypeChildAdded withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
                
                typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
                [self processIncomingEvent:snapshot entityName:entityName];
                
            }]];
            
            
            [self addHandle:[table observeEventType:FIRDataEventTypeChildChanged withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
                typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
                [self processIncomingEvent:snapshot entityName:entityName];
            }]];
        } else {
            DEBUG_LOG(@"Not able to begin observations of entityName %@ table name %@", entityName, tableName);
        }
    }
    
    // Upload changes from local core data to Firebase
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(managedObjectContextWillSave:) name:NSManagedObjectContextWillSaveNotification object:self.managedObjectContext];
}

- (void)processIncomingEvent:(FIRDataSnapshot*)snapshot entityName:(NSString*)entityName {
    if (![self isObserving]) return;
    
    if (![snapshot.value respondsToSelector:@selector(objectForKey:)]) {
        return;
    }
    
    if ([self isDelete:snapshot]) {
        // Delete this record regardless of which device is supposedly the last one
        [self handleDelete:snapshot entityName:entityName inManagedObjectContext:self.childManagedObjectContext];
    } else {
        
        NSString* lastDevice = [snapshot.value objectForKey:self.lastDeviceIdAttributeName];
        BOOL needsUpdate = YES;
        if ((lastDevice != nil) && (lastDevice.length > 0)) {
            if ([lastDevice isEqualToString:self.localDeviceId]) {
                needsUpdate = NO;
            }
        }
        if (needsUpdate) {
            [self updateCoreDataWithFirebaseChanges:@[snapshot] forEntityName:entityName];
        }
        
    }
}

- (void)stopObserving
{
    if (![self isObserving]) return;
    self.observing = NO;
    self.persistentStoreCoordinator = nil;
    
    FIRDatabaseReference* userRoot = [[self.databaseRoot child:@"users"] child:self.userId];
    for (NSNumber* handleContainer in self.databaseHandles) {
        FIRDatabaseHandle handle = [handleContainer longValue];
        [userRoot removeObserverWithHandle:handle];
    }
    
    self.databaseHandles = nil;
    
    [self resetPrioritiesSetOnTables];
    
    if (self.observer != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.observer];
        self.observer = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextWillSaveNotification object:self.managedObjectContext];
}

#pragma mark - Updating Core Data

- (NSManagedObject*)managedObjectForRecord:(FIRDataSnapshot *)record withEntityName:(NSString*)entityName inManagedObjectContext:(NSManagedObjectContext*)managedObjectContext
{
    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:entityName];
    [fetchRequest setFetchLimit:1];
    
    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"%K == %@", self.syncAttributeName, record.key]];
    
    NSError *error = nil;
    NSArray *managedObjects = [managedObjectContext executeFetchRequest:fetchRequest error:&error];
    if (managedObjects)  {
        return [managedObjects lastObject];
    } else {
        DEBUG_LOG(@"Error executing fetch request: %@", error);
        return nil;
    }
}

- (void)processIncomingRecord:(FIRDataSnapshot*)record withEntityName:(NSString*)entityName updates:(NSMutableArray*)updates inManagedObjectContext:(NSManagedObjectContext*)managedObjectContext {
    NSManagedObject* managedObject = [self managedObjectForRecord:record withEntityName:entityName inManagedObjectContext:managedObjectContext];
    
    if (!managedObject) {
        managedObject = [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:managedObjectContext];
        [managedObject setValue:record.key forKey:self.syncAttributeName];
    } else {
        NSNumber* remoteTimestamp = [record.value objectForKey:self.remoteTimestampAttributeName];
        NSNumber* currentRemoteTimestamp = [managedObject valueForKey:self.remoteTimestampAttributeName];
        if ((remoteTimestamp != nil) && ([remoteTimestamp isEqual:currentRemoteTimestamp])) {
            // Ignore updates where the timestamp hasn't changed - not a real update
            return;
        }
    }
    
    [updates addObject:@{PKUpdateManagedObjectKey: managedObject, PKUpdateDocumentKey: record}];
}

- (void)processUpdates:(NSArray*)updates forEntityName:(NSString*)entityName inManagedObjectContext:(NSManagedObjectContext*)managedObjectContext {
    DEBUG_LOG(@"Pulling %d changes to %@", (int)updates.count, entityName);
    
    for (NSDictionary *update in updates) {
        NSManagedObject *managedObject = update[PKUpdateManagedObjectKey];
        FIRDataSnapshot *record = update[PKUpdateDocumentKey];
        if (record != nil) {
            DEBUG_LOG(@"- Pulling %@ %@", entityName, record.key);
            [FIRFirebaseToManagedObject setManagedObjectPropertiesOn:managedObject withRecord:record syncAttributeName:self.syncAttributeName manager:self];
            
            if ((self.delegate != nil) && ([self.delegate respondsToSelector:@selector(managedObjectWasSyncedFromFirebase:syncManager:)])) {
                // Give objects an opportunity to respond to the sync
                [self.delegate managedObjectWasSyncedFromFirebase:managedObject syncManager:self];
            }
            
            if (managedObject.isInserted) {
                // Validate this object quickly
                NSError *error = nil;
                if (![managedObject validateForInsert:&error]) {
                    if ((self.delegate != nil) && ([self.delegate respondsToSelector:@selector(syncManager:managedObject:insertValidationFailed:inManagedObjectContext:)])) {
                        
                        // Call the delegate method to respond to this validation error
                        [self.delegate syncManager:self managedObject:managedObject insertValidationFailed:error inManagedObjectContext:managedObjectContext];
                    }
                }
            }
        } else {
            DEBUG_LOG(@"- Not pulling nil record %@", entityName);
        }
    }
    
    [self finalisePull];
}

- (NSManagedObjectContext*)initialiseChildObjectContext {
    NSManagedObjectContext* managedObjectContext = self.childManagedObjectContext;
    
    if (managedObjectContext == nil) {
        managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        
        [managedObjectContext setParentContext:self.managedObjectContext];
        
        self.childManagedObjectContext = managedObjectContext;
    }
    
    return managedObjectContext;
}

- (void)mergeChildObjectContext:(NSManagedObjectContext*)managedObjectContext {
    if ([managedObjectContext hasChanges]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncManagedObjectContextDidSave:) name:NSManagedObjectContextDidSaveNotification object:managedObjectContext];
        NSError *error = nil;
        if (![managedObjectContext save:&error]) {
            DEBUG_LOG(@"Error saving managed object context: %@", error);
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextDidSaveNotification object:managedObjectContext];
    }
}

- (BOOL)updateCoreDataWithFirebaseChanges:(NSEnumerator*)children forEntityName:(NSString*)entityName
{
    // Start a timer so that we save changes in a moment
    [self resetPullTimer];

    NSManagedObjectContext* managedObjectContext = self.childManagedObjectContext;

    __weak typeof(self) weakSelf = self;
    [managedObjectContext performBlockAndWait:^{
        __block NSMutableArray *updates = [[NSMutableArray alloc] init];
        
        for (FIRDataSnapshot* record in children) {
            [self processIncomingRecord:record withEntityName:entityName updates:updates inManagedObjectContext:managedObjectContext];
        }
        
        
        [self processUpdates:updates forEntityName:entityName inManagedObjectContext:managedObjectContext];
    }];
    
    return YES;
}

- (void)handleDelete:(FIRDataSnapshot*)record entityName:(NSString*)entityName inManagedObjectContext:(NSManagedObjectContext*)context {
    [context performBlockAndWait:^{
        
        NSManagedObject* managedObject = [self managedObjectForRecord:record withEntityName:entityName inManagedObjectContext:context];
        
        if (managedObject) {
            if ((self.delegate != nil) && ([self.delegate respondsToSelector:@selector(willDeleteManagedObjectFromFirebase:syncManager:)])) {
                // Call the delegate
                [self.delegate willDeleteManagedObjectFromFirebase:managedObject syncManager:self];
            }
            
            // Delete this object
            [context deleteObject:managedObject];
        }
       
        [self finalisePull];
    }];
}

- (NSDate*)valueToDate:(id)value {
    if ((value == nil) || (value == [NSNull null]) || ([NSNull isValuePKNull:value])) {
        return nil;
    } else if ([value isKindOfClass:[NSDate class]]) {
        // I don't think this is actually possible but maybe in some magical future Firebase update...
        // Actually, it could be if transformRemoteData returned a date value.
        return (NSDate*)value;
    } else if ([value isKindOfClass:[NSNumber class]]) {
        // Convert from timestamp
        NSTimeInterval timeInterval = [value longValue];
        if (timeInterval >= 1000000000000L) {
            // The value must include milliseconds
            timeInterval /= 1000.0;
        }
        return [NSDate dateWithTimeIntervalSince1970:timeInterval];
    } else if ([value isKindOfClass:[NSString class]]) {
        // See if we can unformat this
        return [self TTTDateFromISO8601Timestamp:value];
    } else {
        return nil;
    }
}

- (BOOL)isDelete:(FIRDataSnapshot*)record {
    id deletedValue = [record.value objectForKey:PKSyncManagerFirebaseDeletedAtKey];
    if (deletedValue != nil) {
        // We have a deleted timestamp - do we have a created timestamp?                
        id value = [record.value objectForKey:@"created"];
        NSDate* created = [self valueToDate:value];
        if (created == nil) {
            // This record has definitely been deleted
            return true;
        } else {
            // See if the record was deleted *after* it was created
            NSDate* deleted = [self valueToDate:deletedValue];
            BOOL isDelete = [created compare:deleted] == NSOrderedAscending;
            return isDelete;
        }
    } else {
        return false;
    }
}

- (void)syncManagedObjectContextDidSave:(NSNotification *)notification
{
    if ([NSThread isMainThread]) {
        [self.managedObjectContext mergeChangesFromContextDidSaveNotification:notification];
    } else {
        [self performSelectorOnMainThread:@selector(syncManagedObjectContextDidSave:) withObject:notification waitUntilDone:YES];
    }
}

#pragma mark - Updating Datastore

- (void)managedObjectContextWillSave:(NSNotification *)notification
{
    if (![self isObserving]) return;
    
    if (!self.currentSyncStatus.uploading) {
        // Start the counters from zero
        self.currentSyncStatus.totalRecordsToUpload = 0;
        self.currentSyncStatus.uploadedRecords = 0;
    }
    self.currentSyncStatus.uploading = YES;
    [self postSyncStatusNotification];
    
    NSManagedObjectContext *managedObjectContext = notification.object;
    if (self.managedObjectContext != managedObjectContext) return;
    
    FIRDatabaseReference* userRoot = [[self.databaseRoot child:@"users"] child:self.userId];
    
    NSSet *deletedObjects = [managedObjectContext deletedObjects];
    if (deletedObjects.count > 0) {
        DEBUG_LOG(@"Total deleted object(s) are %d:", (int)deletedObjects.count);
        for (NSManagedObject* managedObject in deletedObjects) {
            NSString *entityName = [[managedObject entity] name];
            NSString *syncID = [managedObject primitiveValueForKey:self.syncAttributeName];
            DEBUG_LOG(@"* %@ %@", entityName, syncID);
        }
    
        NSDictionary* syncableDeletedObjectsByTableName = [self syncableManagedObjectsByEntityNameFromManagedObjects:deletedObjects];
        for (NSString* tableID in self.sortedEntityNames.reverseObjectEnumerator) {
            NSSet* syncableObjects = [syncableDeletedObjectsByTableName objectForKey:tableID];
            if (syncableObjects != nil) {
                self.currentSyncStatus.totalRecordsToUpload += syncableObjects.count;
                
                dispatch_async(self.queue, ^{
                    for (NSManagedObject *managedObject in syncableObjects) {
                        NSString *tableID = [self tableForEntityName:[[managedObject entity] name]];
                        NSString *syncID = [managedObject primitiveValueForKey:self.syncAttributeName];
                        if (syncID.length > 0) {
                            DEBUG_LOG(@"Syncing delete of %@ / %@", tableID, syncID);
                            FIRDatabaseReference *table = [userRoot child:tableID];
                            FIRDatabaseReference *record = [table child:syncID];
                            if (record) {
                                // Replace with a dictionary with just a single key - the deleted at timestamp
                                [record setValue:@{
                                    PKSyncManagerFirebaseDeletedAtKey: [FIRServerValue timestamp],
                                    self.lastDeviceIdAttributeName: self.localDeviceId
                                } withCompletionBlock:^(NSError * _Nullable error, FIRDatabaseReference * _Nonnull ref) {
                                    [self progressUploadedObject];
                                    if (error != nil) {
                                        DEBUG_LOG(@"Error removing %@ record %@: %@", tableID, ref.key, error);
                                    }
                                }];
                            }
                        } else {
                            DEBUG_LOG(@"Skipping delete of %@ with blank sync ID", tableID);
                        }
                    };
                });
            }
        }
    }
    
    NSMutableSet *managedObjects = [[NSMutableSet alloc] init];
    [managedObjects unionSet:[managedObjectContext insertedObjects]];
    [managedObjects unionSet:[managedObjectContext updatedObjects]];
    
    // Loop over tables in order so that the dependencies work correctly
    NSDictionary* syncableUpdatedObjectsByTableName = [self syncableManagedObjectsByEntityNameFromManagedObjects:managedObjects];
    for (NSString* tableID in self.sortedEntityNames) {
        NSSet* syncableObjects = [syncableUpdatedObjectsByTableName objectForKey:tableID];
        if (syncableObjects != nil) {
            DEBUG_LOG(@"Pushing %d updated object(s) for %@", (int)syncableObjects.count, tableID);
            self.currentSyncStatus.totalRecordsToUpload += syncableObjects.count;
            
            dispatch_async(self.queue, ^{
                for (NSManagedObject *managedObject in syncableObjects) {
                    [self updateFirebaseWithManagedObject:managedObject userRoot:userRoot];
                }
            });
            
            // Mark it as synced as soon as we submit to Firebase
            // (don't wait for callback, or we'll miss our chance to persist a database change)
            [self markObjectsAsSynced:syncableObjects.allObjects];
        }
    }
    
    if (self.currentSyncStatus.totalRecordsToUpload == 0) {
        // Stop upload
        self.currentSyncStatus.uploading = NO;
        [self postSyncStatusNotification];
    }
}

- (void)markObjectsAsSynced:(NSArray*)managedObjects {
    
    dispatch_async(self.queue, ^() {
        NSManagedObjectContext* subContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        
        [subContext setParentContext:self.managedObjectContext];
        
        BOOL hasChanges = NO;
        
        for (NSManagedObject* managedObject in managedObjects) {
            NSError* error = nil;
            if (!managedObject.isDeleted) {
                NSManagedObject* childObject = [subContext existingObjectWithID:managedObject.objectID error:&error];
                if (childObject) {
                    if (![[childObject valueForKey:self.isSyncedAttributeName] boolValue]) {
                        DEBUG_LOG(@"Setting isSynced for %@ %@", childObject.entity.name, [childObject valueForKey:self.syncAttributeName]);
                        [childObject setValue:@YES forKey:self.isSyncedAttributeName];
                        hasChanges = YES;
                    }
                }
            }
        }
        
        if (hasChanges) {
            NSError* error = nil;
            if (![subContext save:&error]) {
                NSLog(@"Error saving sub-context: %@", error);
            } else {
                // Merge into parent context
                [self.managedObjectContext performBlock:^{
                    NSError* parentError = nil;
                    if (![self.managedObjectContext save:&parentError]) {
                        NSLog(@"Error merging isSynced into parent context: %@", parentError);
                    }
                }];
            }
        }
    });
}

- (void)progressUploadedObject {
    if (self.currentSyncStatus.uploadedRecords < self.currentSyncStatus.totalRecordsToUpload) {
        // Mark an extra record uploaded
        self.currentSyncStatus.uploadedRecords ++;
    }
    if (self.currentSyncStatus.uploadedRecords >= self.currentSyncStatus.totalRecordsToUpload) {
        // We have now finished uploading
        self.currentSyncStatus.uploading = NO;
    }
    // Fire off a notification
    [self postSyncStatusNotification];
}

- (void)updateFirebaseWithManagedObject:(NSManagedObject *)managedObject userRoot:(FIRDatabaseReference*)userRoot
{
    NSString *entityName = [[managedObject entity] name];
    NSString *tableID = [self tableForEntityName:entityName];
    if (!tableID) {
        DEBUG_LOG(@"Skipping push of unknown entity name %@", entityName);
        return;
    }
    
    FIRDatabaseReference *table = [userRoot child:tableID];
    
    NSString* recordSyncID = [managedObject valueForKey:self.syncAttributeName];
    
    if (recordSyncID.length == 0) {
        DEBUG_LOG(@"Skipping sync of entity with blank sync ID");
        return;
    }
    
    FIRDatabaseReference *record = [table child:recordSyncID];
    
    DEBUG_LOG(@"Syncing %@ / %@ to %@", entityName, record.key, tableID);
    
    [FIRManagedObjectToFirebase setFieldsOnReference:record withManagedObject:managedObject syncAttributeName:self.syncAttributeName manager:self];
    
    if ((self.delegate != nil) && ([self.delegate respondsToSelector:@selector(managedObjectWasSyncedToFirebase:syncManager:)])) {
        // Call the delegate method
        [self.delegate managedObjectWasSyncedToFirebase:managedObject syncManager:self];
    }
    
    if (![self.prioritiesSetOnTables containsObject:entityName]) {
        NSInteger tableIndex = [self.sortedEntityNames indexOfObject:entityName];
        NSNumber *tablePriority = [NSNumber numberWithInteger:tableIndex];
        [table setPriority:tablePriority];
        [self.prioritiesSetOnTables addObject:entityName];
    }
}

- (NSDictionary *)syncableManagedObjectsByEntityNameFromManagedObjects:(NSSet *)managedObjects
{
    NSMutableDictionary* syncableObjectsByTableName = [NSMutableDictionary dictionaryWithCapacity:self.tablesKeyedByEntityName.count];
    
    //
    for (NSManagedObject *managedObject in managedObjects) {
        NSString *entityName = [[managedObject entity] name];
        if (!entityName) continue;
        
        if ((self.delegate != nil) && ([self.delegate respondsToSelector:@selector(isRecordSyncable:)])) {
            if (![self.delegate isRecordSyncable:managedObject]) {
                continue;
            }
        }
        
        if (![managedObject valueForKey:self.syncAttributeName]) {
            [managedObject setPrimitiveValue:[[self class] syncID] forKey:self.syncAttributeName];
        }
        
        // See if the record has materially changed
        BOOL hasChanges = [self hasManagedObjectChanged:managedObject];
        if ((hasChanges) && ([self.delegate respondsToSelector:@selector(syncManager:hasManagedObjectChanged:)])) {
            // Let the delegate make its own decision
            hasChanges = [self.delegate syncManager:self hasManagedObjectChanged:managedObject];
        }
        if (!hasChanges) {
            DEBUG_LOG(@"Skipping %@ %@ with no changes: %@", managedObject.entity.name, [managedObject valueForKey:self.syncAttributeName], managedObject.changedValues.allKeys);
            continue;
        }
        
        NSMutableSet* syncableManagedObjects = [syncableObjectsByTableName objectForKey:entityName];
        if (syncableManagedObjects == nil) {
            syncableManagedObjects = [[NSMutableSet alloc] init];
            [syncableObjectsByTableName setObject:syncableManagedObjects forKey:entityName];
        }
        [syncableManagedObjects addObject:managedObject];
    }
    
    return syncableObjectsByTableName;
}

- (BOOL)hasManagedObjectChanged:(NSManagedObject *)managedObject {
    if ((managedObject.isInserted) || (managedObject.isDeleted)) {
        // New records have obviously changed
        return YES;
    }
    
    if (managedObject.changedValues.count > 1) {
        // If more than one field has changed, we consider it changed
        return YES;
    }
    
    if (![managedObject.changedValues.allKeys.firstObject isEqualToString:self.isSyncedAttributeName]) {
        // If something other than 'isSynced' has changed, the record has changed
        return YES;
    }
    
    return YES;
}

- (NSString *)TTTISO8601TimestampFromDate:(NSDate *)date {
    // Borrowed gratefully from https://github.com/mattt/TransformerKit
    static NSDateFormatter *_iso8601DateFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _iso8601DateFormatter = [[NSDateFormatter alloc] init];
        [_iso8601DateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];
        [_iso8601DateFormatter setLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]];
    });
    
    return [_iso8601DateFormatter stringFromDate:date];
}

- (NSDate *)TTTDateFromISO8601Timestamp:(NSString *)timestamp {
    if (!timestamp){
        return nil;
    }
    
    static unsigned int const ISO_8601_MAX_LENGTH = 25;
    
    const char *source = [timestamp cStringUsingEncoding:NSUTF8StringEncoding];
    char destination[ISO_8601_MAX_LENGTH];
    size_t length = strlen(source);
    
    if (length == 0) {
        return nil;
    }
    
    if (length == 20 && source[length - 1] == 'Z') {
        memcpy(destination, source, length - 1);
        strncpy(destination + length - 1, "+0000\0", 6);
    } else if (length == 25 && source[22] == ':') {
        memcpy(destination, source, 22);
        memcpy(destination + 22, source + 23, 2);
    } else {
        memcpy(destination, source, MIN(length, ISO_8601_MAX_LENGTH - 1));
    }
    
    destination[sizeof(destination) - 1] = 0;
    
    struct tm time = {
        .tm_isdst = -1,
    };
    
    strptime_l(destination, "%FT%T%z", &time, NULL);
    
    return [NSDate dateWithTimeIntervalSince1970:mktime(&time)];
}

- (void)setLastError:(NSError*)error summary:(NSString*)errorSummary {
    self.currentSyncStatus.lastError = error;
    self.currentSyncStatus.lastErrorSummary = errorSummary;
    
    [self postSyncStatusNotification];
}

@end
