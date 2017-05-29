//
//  NSNull+PKNull.m
//  Pods
//
//  Created by Andy Geers on 10/04/2017.
//
//

#import "NSNull+PKNull.h"

@implementation NSNull (PKNull)

+ (id)PKNull {
    return @"+_(nl)_+";
}

+ (BOOL)isValuePKNull:(id)value {
    if (![value isKindOfClass:[NSString class]]) {
        return NO;
    }
    // Compare with PKNull
    return [(NSString*)value isEqualToString:[NSNull PKNull]];
}

@end
