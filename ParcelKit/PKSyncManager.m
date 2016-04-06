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
#import "NSManagedObject+ParcelKit.h"
#import "CBLDocument+ParcelKit.h"
#import "ParcelKitSyncedObject.h"

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
@property (nonatomic, strong, readwrite) CBLDatabase *database;
@property (nonatomic, strong) NSMutableDictionary *tablesKeyedByEntityName;
@property (nonatomic) BOOL observing;
@property (nonatomic, strong) id observer;
@property (nonatomic, strong) CBLReplication* pullReplication;
@property (nonatomic, strong) CBLReplication* pushReplication;
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

- (instancetype)initWithManagedObjectContext:(NSManagedObjectContext *)managedObjectContext database:(CBLDatabase *)database username:(NSString *)username password:(NSString *)password
{
    self = [self init];
    if (self) {
        _managedObjectContext = managedObjectContext;
        _database = database;
        self.username = username;
        self.password = password;
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

#pragma mark - Observing methods
- (BOOL)isObserving
{
    return self.observing;
}

- (void)startObservingWithGatewayURL:(NSURL*)url
{
    if ([self isObserving]) return;
    self.observing = YES;
    
    __weak typeof(self) weakSelf = self;
    
    self.observer = [[NSNotificationCenter defaultCenter] addObserverForName:kCBLDatabaseChangeNotification
                                                                      object:self.database
                                                                       queue:nil
                                                                       usingBlock:^(NSNotification* n) {
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        if (![strongSelf isObserving]) return;
                
        [strongSelf syncDatabaseChanges:[n.userInfo objectForKey:@"changes"]];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:PKSyncManagerCouchbaseStatusDidChangeNotification object:strongSelf userInfo:@{ /* PKSyncManagerCouchbaseStatusKey:status */ }];
        });
    }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(managedObjectContextWillSave:) name:NSManagedObjectContextWillSaveNotification object:self.managedObjectContext];
    
    // Enable replication
    // Begin replicating with the server    
    CBLReplication* pull = [self.database createPullReplication:url];
    CBLReplication* push = [self.database createPushReplication:url];
    id<CBLAuthenticator> authenticator = [CBLAuthenticator basicAuthenticatorWithName:self.username password:self.password];
    pull.authenticator = authenticator;
    push.authenticator = authenticator;
    pull.continuous = true;
    push.continuous = true;
    [pull start];
    [push start];
    
    self.pullReplication = pull;
    self.pushReplication = push;
}

- (void)stopObserving
{
    if (self.pushReplication) {
        [self.pushReplication stop];
        self.pushReplication = nil;
    }
    if (self.pullReplication ) {
        [self.pullReplication stop];
        self.pullReplication = nil;
    }
    if (![self isObserving]) return;
    self.observing = NO;
    self.persistentStoreCoordinator = nil;
    
    if (self.observer != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.observer];
        self.observer = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextWillSaveNotification object:self.managedObjectContext];
}

#pragma mark - Updating Core Data
- (BOOL)updateCoreDataWithCouchbaseChanges:(NSArray *)changes
{
    static NSString * const PKUpdateManagedObjectKey = @"object";
    static NSString * const PKUpdateDocumentKey = @"document";
    
    if ([changes count] == 0) return NO;
    
    NSManagedObjectContext *managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [managedObjectContext setPersistentStoreCoordinator:self.persistentStoreCoordinator];
    [managedObjectContext setUndoManager:nil];

    __weak typeof(self) weakSelf = self;
    [managedObjectContext performBlockAndWait:^{
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        
        __block NSMutableArray *updates = [[NSMutableArray alloc] init];
        
        typeof(self) weakSelf = strongSelf;
        [changes enumerateObjectsUsingBlock:^(CBLDatabaseChange* change, NSUInteger idx, BOOL *stop) {
            typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
            
            if (change.source != nil) {
                NSLog(@"Processing CBLChange with documentID %@ source %@", change.documentID, change.source);
                CBLDocument* document = [self.database documentWithID:change.documentID];
                
                NSString *entityName = [document propertyForKey:@"entity_name_"];
                if (!entityName) return;
                
                NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:entityName];
                [fetchRequest setFetchLimit:1];
                
                [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"%K == %@", strongSelf.syncAttributeName, [document propertyForKey:@"sync_id_"]]];
                
                NSError *error = nil;
                NSArray *managedObjects = [managedObjectContext executeFetchRequest:fetchRequest error:&error];
                if (managedObjects)  {
                    NSManagedObject *managedObject = [managedObjects lastObject];
                    
                    if ([document isDeleted]) {
                        if (managedObject) {
                            [managedObjectContext deleteObject:managedObject];
                        }
                    } else {
                        if (!managedObject) {
                            managedObject = [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:managedObjectContext];
                            [managedObject setValue:[self syncIDFromDocumentID:change.documentID] forKey:strongSelf.syncAttributeName];
                        }
                        
                        [updates addObject:@{PKUpdateManagedObjectKey: managedObject, PKUpdateDocumentKey: document}];
                    }
                } else {
                    NSLog(@"Error executing fetch request: %@", error);
                }
            } else {
                NSLog(@"Ignoring CBLChange with nil source");
            }
        }];
        
        
        for (NSDictionary *update in updates) {
            NSManagedObject *managedObject = update[PKUpdateManagedObjectKey];
            CBLDocument *record = update[PKUpdateDocumentKey];
            [managedObject pk_setPropertiesWithRecord:record syncAttributeName:strongSelf.syncAttributeName manager:self];
            
            if ((self.delegate != nil) && ([self.delegate respondsToSelector:@selector(managedObjectWasSyncedFromCouchbase:syncManager:)])) {
                // Give objects an opportunity to respond to the sync
                [self.delegate managedObjectWasSyncedFromCouchbase:managedObject syncManager:self];
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
    
    NSSet *deletedObjects = [managedObjectContext deletedObjects];
    for (NSManagedObject *managedObject in [self syncableManagedObjectsFromManagedObjects:deletedObjects]) {
        NSError *error = nil;
        [self.database deleteLocalDocumentWithID:[self documentIDFromObject:managedObject] error:&error];
    };
    
    NSMutableSet *managedObjects = [[NSMutableSet alloc] init];
    [managedObjects unionSet:[managedObjectContext insertedObjects]];
    [managedObjects unionSet:[managedObjectContext updatedObjects]];
    
    for (NSManagedObject *managedObject in [self syncableManagedObjectsFromManagedObjects:managedObjects]) {
        [self updateCouchbaseWithManagedObject:managedObject];
    }
}

- (void)updateCouchbaseWithManagedObject:(NSManagedObject *)managedObject
{
    NSString *tableID = [self tableForEntityName:[[managedObject entity] name]];
    if (!tableID) return;
    
    CBLDocument *record = [self.database documentWithID:[self documentIDFromObject:managedObject]];
    [record pk_setFieldsWithManagedObject:managedObject syncAttributeName:self.syncAttributeName manager:self];
    
    if ((self.delegate != nil) && ([self.delegate respondsToSelector:@selector(managedObjectWasSyncedToCouchbase:syncManager:)])) {
        // Call the delegate method
        [self.delegate managedObjectWasSyncedToCouchbase:managedObject syncManager:self];
    }
}

- (void)syncDatabaseChanges:(NSArray*)changes
{
    if (changes.count > 0) {
        if ([self updateCoreDataWithCouchbaseChanges:changes]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:PKSyncManagerCouchbaseIncomingChangesNotification object:self userInfo:@{PKSyncManagerCouchbaseIncomingChangesKey: changes}];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:PKSyncManagerCouchbaseLastSyncDateNotification object:self userInfo:@{PKSyncManagerCouchbaseLastSyncDateKey: [NSDate date]}];
    }
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

- (NSString*)syncIDFromDocumentID:(NSString*)documentID {
    NSArray* components = [documentID componentsSeparatedByString:@":"];
    return [components lastObject];
}

- (NSString*)documentIDFromObject:(NSManagedObject*)object {
    NSString* tablePrefix = [self tableForEntityName:[[object entity] name]];
    NSString* syncID = [object valueForKey:self.syncAttributeName];
    
    return [self documentIDFromTablePrefix:tablePrefix recordID:syncID];
}

- (NSString*)documentIDFromTablePrefix:(NSString*)tablePrefix recordID:(NSString*)recordID {
    return [NSString stringWithFormat:@"%@:%@", tablePrefix, recordID];
}

@end
