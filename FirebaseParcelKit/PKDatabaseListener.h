//
//  PKDatabaseListener.h
//  FirebaseParcelKit
//
//  Created by Andy Geers on 15/12/2017.
//  Copyright © 2017 Overcommitted, LLC. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <FirebaseDatabase/FirebaseDatabase.h>

@interface PKDatabaseListener : NSObject

@property (nonatomic, strong) FIRDatabaseReference* reference;
@property (nonatomic) FIRDatabaseHandle listener;

- (id)initWithListener:(FIRDatabaseHandle)listener onTable:(FIRDatabaseReference*)table;

@end
