//
//  NSNull+PKNull.h
//  Pods
//
//  Created by Andy Geers on 10/04/2017.
//
//

#import <Foundation/Foundation.h>

@interface NSNull (PKNull)

+ (id)PKNull;
+ (BOOL)isValuePKNull:(id)value;

@end
