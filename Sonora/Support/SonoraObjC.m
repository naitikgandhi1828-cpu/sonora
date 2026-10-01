//
//  SonoraObjC.m
//  Sonora
//

#import "SonoraObjC.h"

@implementation SonoraObjC

+ (nullable NSString *)catchException:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@",
                exception.name, exception.reason ?: @"(no reason)"];
    }
}

@end
