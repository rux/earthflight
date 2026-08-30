#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CesiumBridge : NSObject

+ (NSString *)runSmokeTest;
+ (NSString *)runCartographicRoundTripSmokeTest;
+ (NSString *)decoratedGoogleURLForTesting:(NSString *)url apiKey:(NSString *)apiKey;
+ (NSString *)runLondonLocalFrameSmokeTest;
+ (void)startStaticLondonTilesWithAPIKey:(NSString *)apiKey;
+ (void)updateStaticLondonTiles;

@end

NS_ASSUME_NONNULL_END
