//
//  SonoraObjC.h
//  Sonora
//
//  AVAudioEngine reports some failures (starting with no output, connecting
//  a bad format, installing a tap twice) by raising an Objective-C exception.
//  Swift cannot catch those, so the app would simply crash. This tiny
//  Objective-C shim catches them and hands back the reason instead.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SonoraObjC : NSObject

/// Runs `block`. Returns nil if it finished normally, or the exception's
/// reason if it raised one.
+ (nullable NSString *)catchException:(NS_NOESCAPE void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
