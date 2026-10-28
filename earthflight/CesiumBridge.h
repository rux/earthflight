#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

/// One drawable glTF primitive, decoded and flattened for RealityKit.
@interface CesiumPrimitivePayload : NSObject

/// Float x, y, z per vertex: metres in the primitive's own local frame.
@property (nonatomic, readonly) NSData *positions;
/// Float u, v per vertex, already converted to RealityKit's V convention.
@property (nonatomic, readonly) NSData *textureCoordinates;
/// UInt32 triangle list.
@property (nonatomic, readonly) NSData *indices;
/// Tightly packed RGBA8 base-colour texels, sRGB, top row first.
@property (nonatomic, readonly) NSData *rgbaImage;
@property (nonatomic, readonly) NSInteger imageWidth;
@property (nonatomic, readonly) NSInteger imageHeight;
/// glTF sampler enumerations.
@property (nonatomic, readonly) NSInteger samplerWrapS;
@property (nonatomic, readonly) NSInteger samplerWrapT;
@property (nonatomic, readonly) NSInteger samplerMinFilter;
@property (nonatomic, readonly) NSInteger samplerMagFilter;
@property (nonatomic, readonly) BOOL doubleSided;
/// Primitive-local -> ECEF: X east, Y geodetic up, Z south, metres.
@property (nonatomic, readonly) simd_double4x4 ecefFromPrimitiveLocal;

@end

/// How Cesium chooses tiles. Every field comes from `EarthflightTuning`, which
/// documents each one.
typedef struct {
    double maximumScreenSpaceErrorHeadsetPixels;
    double headsetPixelsPerDegree;
    double horizontalFieldOfViewDegrees;
    double verticalFieldOfViewDegrees;
    bool forbidHoles;
    uint32_t loadingDescendantLimit;
    uint32_t maximumSimultaneousTileLoads;
    int64_t maximumCachedBytes;
} CesiumTileSelectionSettings;

/// The first surface straight below a point, and how coarse the tile it was
/// found in is. Both are NaN when no tile Cesium holds lies below the point.
typedef struct {
    double ellipsoidHeightMeters;
    /// The tile's geometric error: roughly how far its mesh may stray from the
    /// true surface.
    double geometricErrorMeters;
} CesiumGroundSample;

@interface CesiumBridge : NSObject

// WGS84 conversions. Angles are degrees; positions and heights are metres.
+ (simd_double3)ecefPositionWithLongitudeDegrees:(double)longitudeDegrees
                                  latitudeDegrees:(double)latitudeDegrees
                           ellipsoidHeightMeters:(double)ellipsoidHeightMeters;
/// Longitude, latitude and ellipsoid height, or NaN in all three at the
/// Earth's centre, where there is no answer.
+ (simd_double3)cartographicDegreesFromEcefPosition:(simd_double3)ecefPosition;
/// Local -> ECEF for the tangent frame at a point: X east, Y geodetic up, Z south.
+ (simd_double4x4)ecefFromLocalHorizontalAtEcefPosition:(simd_double3)ecefPosition;
+ (double)egm96HeightAboveWGS84EllipsoidAtLongitudeDegrees:(double)longitudeDegrees
                                           latitudeDegrees:(double)latitudeDegrees;

// The tileset and everything belonging to the running session live in plain
// globals with no locks, and `updateTiles` drains Cesium's main-thread task
// queue, so these methods are main-thread-only by construction.
// `NS_SWIFT_UI_ACTOR` states that to Swift so the compiler checks it, and marks
// the callbacks as what they are: every one runs on the main queue,
// `onPrepareTile` and `onTileFreed` through `dispatch_async` and the other three
// synchronously from `updateTiles`.
//
// Per update: `onTileSelected` for every drawable tile Cesium selected, then
// `onSelectionComplete` if every selected tile was ready to draw.
+ (void)startTilesWithAPIKey:(NSString *)apiKey
                    settings:(CesiumTileSelectionSettings)settings
               onPrepareTile:(void (^ NS_SWIFT_UI_ACTOR)(uint64_t tileIdentifier, NSArray<CesiumPrimitivePayload *> *primitives))onPrepareTile
              onTileSelected:(void (^ NS_SWIFT_UI_ACTOR)(uint64_t tileIdentifier))onTileSelected
         onSelectionComplete:(void (^ NS_SWIFT_UI_ACTOR)(void))onSelectionComplete
                 onTileFreed:(void (^ NS_SWIFT_UI_ACTOR)(uint64_t tileIdentifier))onTileFreed
        onAttributionChanged:(void (^ NS_SWIFT_UI_ACTOR)(NSString *attribution))onAttributionChanged NS_SWIFT_UI_ACTOR;
/// The camera is the wearer's head in ECEF. Direction and up need not be unit
/// length or exactly perpendicular.
+ (void)updateTilesWithCameraPosition:(simd_double3)ecefPosition
                            direction:(simd_double3)ecefDirection
                                   up:(simd_double3)ecefUp
                            deltaTime:(double)deltaTime NS_SWIFT_UI_ACTOR;
/// Casts a ray along geodetic down from `ecefPosition` against tiles already
/// loaded, preferring the most detailed. It loads nothing, so it costs no
/// network or RealityKit work, and anything above the point never counts.
+ (CesiumGroundSample)groundBelowEcefPosition:(simd_double3)ecefPosition
    NS_SWIFT_NAME(groundBelow(ecefPosition:)) NS_SWIFT_UI_ACTOR;
/// Answers one `onPrepareTile`. Deliberately not main-actor: it takes a mutex
/// and resolves a Cesium promise, both safe from any thread.
+ (void)tileDidFinishPreparing:(uint64_t)tileIdentifier succeeded:(BOOL)succeeded;
/// Seconds since Google last refused a request for coming too fast (HTTP 429),
/// or infinity if it never has. Reads an atomic, so safe from any thread.
@property (class, nonatomic, readonly) double secondsSinceRateLimit;
+ (void)stopTiles NS_SWIFT_UI_ACTOR;

// Test seams for two internal steps that have no public route in.
+ (NSString *)decoratedGoogleURLForTesting:(NSString *)url apiKey:(NSString *)apiKey;
+ (NSArray<NSNumber *> *)realityKitTextureCoordinateForTestingWithU:(double)u
                                                                  v:(double)v
                                                            offsetU:(double)offsetU
                                                            offsetV:(double)offsetV
                                                             scaleU:(double)scaleU
                                                             scaleV:(double)scaleV
                                                           rotation:(double)rotation;

@end

NS_ASSUME_NONNULL_END
