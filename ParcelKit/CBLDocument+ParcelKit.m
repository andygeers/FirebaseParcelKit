//
//  DBRecord+ParcelKit.m
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

#import "CBLDocument+ParcelKit.h"
#import "PKConstants.h"
#import "NSManagedObject+ParcelKit.h"
#import "ParcelKitSyncedObject.h"

#ifndef PKMaximumBinaryDataChunkLengthInBytes
#define PKMaximumBinaryDataChunkLengthInBytes 95000
#endif

@implementation CBLDocument (ParcelKit)

- (void)pk_setFieldsWithManagedObject:(NSManagedObject *)managedObject syncAttributeName:(NSString *)syncAttributeName manager:(PKSyncManager*)manager
{
    __weak typeof(self) weakSelf = self;
    NSDictionary *propertiesByName = [[managedObject entity] propertiesByName];
    NSArray *fieldNames = [[self userProperties] allKeys];
    
    NSDictionary *values = nil;
    if ([managedObject respondsToSelector:@selector(syncedPropertiesDictionary:)]) {
        // Get the custom properties dictionary
        values = [managedObject performSelector:@selector(syncedPropertiesDictionary:) withObject:propertiesByName];
    } else {
        // Get the standard properties dictionary
        values = [managedObject dictionaryWithValuesForKeys:[propertiesByName allKeys]];
    }
    
    NSMutableDictionary* newProperties = [self.properties mutableCopy];
    
    [newProperties setObject:managedObject.entity.name forKey:@"_entity_name"];
    
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *name, id value, BOOL *stop) {
        typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
        
        if ([name isEqualToString:syncAttributeName]) return;

        NSPropertyDescription *propertyDescription = [propertiesByName objectForKey:name];
        if ([propertyDescription isTransient]) return;

        if (value && value != [NSNull null]) {
            if ((propertyDescription == nil) || [propertyDescription isKindOfClass:[NSAttributeDescription class]]) {
                id previousValue = [strongSelf propertyForKey:name];

                NSAttributeType attributeType = [(NSAttributeDescription *)propertyDescription attributeType];
                if ((propertyDescription == nil) || (attributeType != NSBinaryDataAttributeType)) {
                    if (!previousValue || ([previousValue class] != [value class]) || ([previousValue compare:value] != NSOrderedSame)) {
                        [newProperties setObject:value forKey:name];
                    }
                } else {
                    
                    // Only sync data if it's changed
                    NSData *data = value;
                    id previousData = [self propertyForKey:name];
                    if (![data isEqualToData:previousData]) {
                        [newProperties setObject:data forKey:name];
                    }
                }
            } else if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
                NSRelationshipDescription *relationshipDescription = (NSRelationshipDescription *)propertyDescription;
                if ([relationshipDescription isToMany]) {
                    // See if the inverse relationship is to-one, and if so we don't need
                    // to bother storing the relationship on this table at all (it'll lead to
                    // fewer potential inconsistencies if we don't)
                    NSRelationshipDescription* inverse = [relationshipDescription inverseRelationship];
                    if ([inverse isToMany]) {
                        NSOrderedSet *currentObjects = ([relationshipDescription isOrdered] ? value : [[NSOrderedSet alloc] initWithArray:[value allObjects]]);
                        
                        NSMutableArray* mappedAndFilteredIdentifiers = [[NSMutableArray alloc] initWithCapacity:currentObjects.count];
                        
                        [currentObjects enumerateObjectsUsingBlock:^(id object, NSUInteger idx, BOOL *stop) {
                            BOOL isSyncable = YES;
                            if ((manager.delegate != nil) && ([manager.delegate respondsToSelector:@selector(isRecordSyncable:)])) {
                                // Don't links to un-synced objects
                                isSyncable = [manager.delegate isRecordSyncable:object];
                            }
                            
                            if (isSyncable) {
                                [mappedAndFilteredIdentifiers addObject:[manager documentIDFromObject:object]];
                            }
                        }];
                        
                        [newProperties setObject:mappedAndFilteredIdentifiers forKey:name];
                    }
                } else {
                    [newProperties setObject:[manager documentIDFromObject:value] forKey:name];
                }
            }
        } else {
            if ([fieldNames containsObject:name]) {
                [newProperties removeObjectForKey:name];
            }
        }
    }];
    
    // Update the properties
    NSError* error = nil;
    [self putProperties:newProperties error:&error];
    if (error != nil) {
        NSLog(@"Error updating Couchbase: %@", error);
    }
}

@end
