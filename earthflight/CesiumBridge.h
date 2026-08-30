#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CesiumPrimitivePayload : NSObject

@property (nonatomic, readonly) NSData *positions;
@property (nonatomic, readonly) NSData *textureCoordinates;
@property (nonatomic, readonly) NSData *indices;
@property (nonatomic, readonly) NSData *rgbaImage;
@property (nonatomic, readonly) NSInteger imageWidth;
@property (nonatomic, readonly) NSInteger imageHeight;
@property (nonatomic, readonly) BOOL doubleSided;

@end

@interface CesiumBridge : NSObject

+ (NSString *)runSmokeTest;
+ (NSString *)runCartographicRoundTripSmokeTest;
+ (NSString *)decoratedGoogleURLForTesting:(NSString *)url apiKey:(NSString *)apiKey;
+ (NSString *)runLondonLocalFrameSmokeTest;
+ (void)startStaticLondonTilesWithAPIKey:(NSString *)apiKey;
+ (void)startStaticLondonTilesWithAPIKey:(NSString *)apiKey
                             onTileReady:(void (^)(NSString *tileIdentifier, NSArray<CesiumPrimitivePayload *> *primitives))onTileReady;
+ (void)startStaticLondonTilesWithAPIKey:(NSString *)apiKey
                           onTileVisible:(void (^)(NSString *tileIdentifier, NSArray<CesiumPrimitivePayload *> *primitives))onTileVisible
                              onTileFreed:(void (^)(NSString *tileIdentifier))onTileFreed;
+ (void)updateStaticLondonTiles;

@end

NS_ASSUME_NONNULL_END
