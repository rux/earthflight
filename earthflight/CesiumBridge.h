#import <Foundation/Foundation.h>
#import <simd/simd.h>

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
@property (nonatomic, readonly) simd_double4x4 ecefFromPrimitiveLocal;

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
+ (NSString *)runLocalHorizontalFrameSmokeTest;
+ (simd_double3)ecefPositionWithLongitudeDegrees:(double)longitudeDegrees
                                  latitudeDegrees:(double)latitudeDegrees
                           ellipsoidHeightMeters:(double)ellipsoidHeightMeters;
+ (simd_double3)cartographicDegreesFromEcefPosition:(simd_double3)ecefPosition;
+ (simd_double4x4)ecefFromLocalHorizontalAtEcefPosition:(simd_double3)ecefPosition;
+ (double)egm96HeightAboveWGS84EllipsoidAtLongitudeDegrees:(double)longitudeDegrees
                                           latitudeDegrees:(double)latitudeDegrees;
+ (void)startTilesWithAPIKey:(NSString *)apiKey
           maximumScreenSpaceError:(double)maximumScreenSpaceError
      maximumSimultaneousTileLoads:(uint32_t)maximumSimultaneousTileLoads
                maximumCachedBytes:(int64_t)maximumCachedBytes
              lodTransitionsEnabled:(BOOL)lodTransitionsEnabled
          lodTransitionLengthSeconds:(float)lodTransitionLengthSeconds
                     forbidTileHoles:(BOOL)forbidTileHoles
       onTilePreparationRequested:(void (^)(NSString *tileIdentifier, NSArray<CesiumPrimitivePayload *> *primitives))onTilePreparationRequested
                     onTileVisible:(void (^)(NSString *tileIdentifier))onTileVisible
              onRenderSetComplete:(void (^)(void))onRenderSetComplete
                        onTileFreed:(void (^)(NSString *tileIdentifier))onTileFreed
              onAttributionChanged:(void (^)(NSString *attribution))onAttributionChanged;
+ (void)updateTilesWithEcefCameraPositionX:(double)positionX
                                   positionY:(double)positionY
                                   positionZ:(double)positionZ
                                  directionX:(double)directionX
                                  directionY:(double)directionY
                                  directionZ:(double)directionZ
                                         upX:(double)upX
                                         upY:(double)upY
                                         upZ:(double)upZ
                                   deltaTime:(double)deltaTime;
+ (void)tileDidFinishPreparing:(NSString *)tileIdentifier succeeded:(BOOL)succeeded;

@end

NS_ASSUME_NONNULL_END
