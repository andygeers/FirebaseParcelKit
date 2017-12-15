//
//  PKDatabaseListener.m
//  FirebaseParcelKit
//
//  Created by Andy Geers on 15/12/2017.
//  Copyright © 2017 Overcommitted, LLC. All rights reserved.
//

#import "PKDatabaseListener.h"

@implementation PKDatabaseListener

- (id)initWithListener:(FIRDatabaseHandle)listener onTable:(FIRDatabaseReference*)table {
    if (self = [super init]) {
        self.reference = table;
        self.listener = listener;
    }
    return self;
}

@end

