#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CesiumPrimitivePayload : NSObject

@property (nonatomic, readonly) NSData *positions;
@property (nonatomic, readonly) NSData *textureCoordinates;
@property (nonatomic, readonly) NSData *indices;
@property (nonatomic, readonly) NSData *rgbaImage;
@property (nonatomic, readonly) NSInteger imageWidth;
@property (nonatomic, readonly) NSInteger imageHeight;
@property (nonatomic, readonly) NSInteger samplerWrapS;
@property (nonatomic, readonly) NSInteger samplerWrapT;
@property (nonatomic, readonly) NSInteger samplerMinFilter;
@property (nonatomic, readonly) NSInteger samplerMagFilter;
@property (nonatomic, readonly) BOOL doubleSided;

@end

@interface CesiumBridge : NSObject

+ (NSString *)runSmokeTest;
+ (NSString *)runCartographicRoundTripSmokeTest;
+ (NSString *)decoratedGoogleURLForTesting:(NSString *)url apiKey:(NSString *)apiKey;
+ (NSArray<NSNumber *> *)realityKitTextureCoordinateForTestingWithU:(double)u
                                                                  v:(double)v
                                                            offsetU:(double)offsetU
                                                            offsetV:(double)offsetV
                                                             scaleU:(double)scaleU
                                                             scaleV:(double)scaleV
                                                           rotation:(double)rotation;
+ (NSString *)runLondonLocalFrameSmokeTest;
+ (void)startStaticLondonTilesWithAPIKey:(NSString *)apiKey;
+ (void)startStaticLondonTilesWithAPIKey:(NSString *)apiKey
                             onTileReady:(void (^)(NSString *tileIdentifier, NSArray<CesiumPrimitivePayload *> *primitives))onTileReady;
+ (void)startStaticLondonTilesWithAPIKey:(NSString *)apiKey
                           onTileVisible:(void (^)(NSString *tileIdentifier, NSArray<CesiumPrimitivePayload *> *primitives))onTileVisible
                              onTileFreed:(void (^)(NSString *tileIdentifier))onTileFreed
                    onAttributionChanged:(void (^)(NSString *attribution))onAttributionChanged;
+ (void)updateStaticLondonTiles;

@end

NS_ASSUME_NONNULL_END
