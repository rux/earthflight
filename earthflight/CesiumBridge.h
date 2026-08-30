#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CesiumBridge : NSObject

+ (NSString *)runSmokeTest;
+ (NSString *)runCartographicRoundTripSmokeTest;

@end

NS_ASSUME_NONNULL_END
