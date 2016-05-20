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

NSString * const PKDefaultSyncAttributeName = @"syncID";
NSString * const PKSyncManagerCouchbaseStatusDidChangeNotification = @"PKSyncManagerDatastoreStatusDidChange";
NSString * const PKSyncManagerCouchbaseStatusKey = @"status";
NSString * const PKSyncManagerCouchbaseIncomingChangesNotification = @"PKSyncManagerDatastoreIncomingChanges";
NSString * const PKSyncManagerCouchbaseIncomingChangesKey = @"changes";
NSString * const PKSyncManagerCouchbaseLastSyncDateNotification = @"PKSyncManagerDatastoreLastSyncDateNotification";
NSString * const PKSyncManagerCouchbaseLastSyncDateKey = @"lastSyncDate";

@interface PKSyncManager ()
@property (nonatomic, strong) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (nonatomic, strong, readwrite) NSManagedObjectContext *managedObjectContext;
@property (nonatomic, strong, readwrite) FIRDatabaseReference *database;
@property (nonatomic, strong) NSMutableDictionary *tablesKeyedByEntityName;
@property (nonatomic) BOOL observing;
@property (nonatomic, strong) id observer;
@property (nonatomic, strong) NSArray* databaseHandles;
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
        _syncBatchSize = 20;
    }
    return self;
}

- (instancetype)initWithManagedObjectContext:(NSManagedObjectContext *)managedObjectContext databaseRoot:(FIRDatabaseReference *)databaseRoot userId:(NSString*)userId
{
    self = [self init];
    if (self) {
        _managedObjectContext = managedObjectContext;
        _databaseRoot = databaseRoot;
        self.userId = userId;
    }
    return self;
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

#pragma mark - Entity and Table map
- (void)setTablesForEntityNamesWithDictionary:(NSDictionary *)keyedTables
{
    for (NSString *entityName in [self entityNames]) {
        [self removeTableForEntityName:entityName];
    }

    __weak typeof(self) weakSelf = self;
    [keyedTables enumerateKeysAndObjectsUsingBlock:^(NSString *entityName, NSString *tableID, BOOL *stop) {
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        [strongSelf setTable:tableID forEntityName:entityName];
    }];
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

- (void)startPullTimer {
    
}

- (void)resetPullTimer {
    
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
    
    NSLog(@"Initialise pull from user root %@", [userRoot key]);
    
    // Loop over all of the tables
    [self addHandle:[userRoot observeEventType:FIRDataEventTypeChildAdded withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        if (![strongSelf isObserving]) return;
        
        [strongSelf resetPullTimer];
        
        [strongSelf syncDatabaseChanges:snapshot];
    }]];
    
    [userRoot observeEventType:FIRDataEventTypeChildChanged withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        
        [strongSelf resetPullTimer];
    }];
    [userRoot observeEventType:FIRDataEventTypeChildRemoved withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
        
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        
        [strongSelf resetPullTimer];
    }];
    [userRoot observeEventType:FIRDataEventTypeChildMoved withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        
        [strongSelf resetPullTimer];
    }];
    
    
    /*
    self.observer = [[NSNotificationCenter defaultCenter] addObserverForName:kCBLDatabaseChangeNotification
                                                                      object:self.database
                                                                       queue:nil
                                                                       usingBlock:^(NSNotification* n) {
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        if (![strongSelf isObserving]) return;
                
        // Filter out the changes that are from the sync gateway rather than local
        NSPredicate* fromGatewayPred = [NSPredicate predicateWithBlock:^BOOL(CBLDatabaseChange* _Nonnull change, NSDictionary<NSString *,id> * _Nullable bindings) {
            return change.source != nil;
        }];
        NSArray* changes = [[n.userInfo objectForKey:@"changes"] filteredArrayUsingPredicate:fromGatewayPred];
                                                                           
        [strongSelf syncDatabaseChanges:changes];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:PKSyncManagerCouchbaseStatusDidChangeNotification object:strongSelf userInfo:@{ ** PKSyncManagerCouchbaseStatusKey:status ** }];
        });
    }];
    */
    
    // Start pulling down changes from Firebase
    
    
    // Upload changes from local core data to Firebase
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(managedObjectContextWillSave:) name:NSManagedObjectContextWillSaveNotification object:self.managedObjectContext];
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
        NSLog(@"Error executing fetch request: %@", error);
        return nil;
    }
}

- (BOOL)updateCoreDataWithFirebaseChanges:(FIRDataSnapshot *)snapshot
{
    static NSString * const PKUpdateManagedObjectKey = @"object";
    static NSString * const PKUpdateDocumentKey = @"document";
    
    NSManagedObjectContext *managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [managedObjectContext setPersistentStoreCoordinator:self.persistentStoreCoordinator];
    [managedObjectContext setUndoManager:nil];

    __weak typeof(self) weakSelf = self;
    [managedObjectContext performBlockAndWait:^{
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        
        NSString *entityName = [self entityNameForTable:snapshot.key];
        if (!entityName) return;
        
        __block NSMutableArray *updates = [[NSMutableArray alloc] init];
        
        typeof(self) weakSelf = strongSelf;
        for (FIRDataSnapshot* record in snapshot.children) {
            NSManagedObject* managedObject = [self managedObjectForRecord:record withEntityName:entityName inManagedObjectContext:managedObjectContext];
            
            /*
            if ([document isDeleted]) {
                if (managedObject) {
                    [managedObjectContext deleteObject:managedObject];
                }
            } else {
             */
                if (!managedObject) {
                    managedObject = [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:managedObjectContext];
                    [managedObject setValue:record.key forKey:strongSelf.syncAttributeName];
                }
                
                [updates addObject:@{PKUpdateManagedObjectKey: managedObject, PKUpdateDocumentKey: record}];
            //}
        }
        
        for (NSDictionary *update in updates) {
            NSManagedObject *managedObject = update[PKUpdateManagedObjectKey];
            FIRDataSnapshot *record = update[PKUpdateDocumentKey];
            [FIRFirebaseToManagedObject setManagedObjectPropertiesOn:managedObject withRecord:record syncAttributeName:strongSelf.syncAttributeName manager:self];
            
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
        }
        
        if ([managedObjectContext hasChanges]) {
            [[NSNotificationCenter defaultCenter] addObserver:strongSelf selector:@selector(syncManagedObjectContextDidSave:) name:NSManagedObjectContextDidSaveNotification object:managedObjectContext];
            NSError *error = nil;
            if (![managedObjectContext save:&error]) {
                NSLog(@"Error saving managed object context: %@", error);
            }
            [[NSNotificationCenter defaultCenter] removeObserver:strongSelf name:NSManagedObjectContextDidSaveNotification object:managedObjectContext];
        }
    }];
    
    return YES;
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
    
    NSManagedObjectContext *managedObjectContext = notification.object;
    if (self.managedObjectContext != managedObjectContext) return;
    
    FIRDatabaseReference* userRoot = [[self.databaseRoot child:@"users"] child:self.userId];
    
    NSSet *deletedObjects = [managedObjectContext deletedObjects];
    for (NSManagedObject *managedObject in [self syncableManagedObjectsFromManagedObjects:deletedObjects]) {
        NSString *tableID = [self tableForEntityName:[[managedObject entity] name]];
        FIRDatabaseReference *table = [userRoot child:tableID];
        FIRDatabaseReference *record = [table child:[managedObject primitiveValueForKey:self.syncAttributeName]];
        if (record) {
            [record removeValueWithCompletionBlock:^(NSError * _Nullable error, FIRDatabaseReference * _Nonnull ref) {
                
                NSLog(@"Error removing %@ record %@: %@", tableID, ref.key, error);
            }];
        }
    };
    
    NSMutableSet *managedObjects = [[NSMutableSet alloc] init];
    [managedObjects unionSet:[managedObjectContext insertedObjects]];
    [managedObjects unionSet:[managedObjectContext updatedObjects]];
    
    for (NSManagedObject *managedObject in [self syncableManagedObjectsFromManagedObjects:managedObjects]) {
        [self updateFirebaseWithManagedObject:managedObject userRoot:userRoot];
    }
}

- (void)updateFirebaseWithManagedObject:(NSManagedObject *)managedObject userRoot:(FIRDatabaseReference*)userRoot
{
    NSString *tableID = [self tableForEntityName:[[managedObject entity] name]];
    if (!tableID) return;
    
    FIRDatabaseReference *table = [userRoot child:tableID];
    FIRDatabaseReference *record = [table child:[managedObject valueForKey:self.syncAttributeName]];
    
    [FIRManagedObjectToFirebase setFieldsOnReference:record withManagedObject:managedObject syncAttributeName:self.syncAttributeName manager:self];
    
    if ((self.delegate != nil) && ([self.delegate respondsToSelector:@selector(managedObjectWasSyncedToFirebase:syncManager:)])) {
        // Call the delegate method
        [self.delegate managedObjectWasSyncedToFirebase:managedObject syncManager:self];
    }
}

- (void)syncDatabaseChanges:(FIRDataSnapshot*)changes
{
    if ([self updateCoreDataWithFirebaseChanges:changes]) {
        /*
        [[NSNotificationCenter defaultCenter] postNotificationName:PKSyncManagerCouchbaseIncomingChangesNotification object:self userInfo:@{PKSyncManagerCouchbaseIncomingChangesKey: changes}];
         */
    }
    /*
    [[NSNotificationCenter defaultCenter] postNotificationName:PKSyncManagerCouchbaseLastSyncDateNotification object:self userInfo:@{PKSyncManagerCouchbaseLastSyncDateKey: [NSDate date]}];
     */
}

- (NSSet *)syncableManagedObjectsFromManagedObjects:(NSSet *)managedObjects
{
    NSMutableSet *syncableManagedObjects = [[NSMutableSet alloc] init];
    for (NSManagedObject *managedObject in managedObjects) {
        NSString *tableID = [self tableForEntityName:[[managedObject entity] name]];
        if (!tableID) continue;
        
        if ((self.delegate != nil) && ([self.delegate respondsToSelector:@selector(isRecordSyncable:)])) {
            if (![self.delegate isRecordSyncable:managedObject]) {
                continue;
            }
        }
        
        if (![managedObject valueForKey:self.syncAttributeName]) {
            [managedObject setPrimitiveValue:[[self class] syncID] forKey:self.syncAttributeName];
        }
        
        [syncableManagedObjects addObject:managedObject];
    }
    
    return [[NSSet alloc] initWithSet:syncableManagedObjects];
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

@end
