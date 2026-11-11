#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

/// One drawable glTF primitive, decoded and flattened for RealityKit.
@interface CesiumPrimitivePayload : NSObject

/// One `simd_float3` per vertex: metres in the primitive's own local frame.
/// Swift reads the buffer as `SIMD3<Float>` without reshaping it.
@property (nonatomic, readonly) NSData *positions;
/// One `simd_float2` per vertex, already converted to RealityKit's V convention.
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

/// A WGS84 position: angles in degrees, height in metres above the ellipsoid.
typedef struct {
    double longitudeDegrees;
    double latitudeDegrees;
    double ellipsoidHeightMeters;
} CesiumCartographic;

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

// MARK: WGS84
//
// Pure conversions, safe from any thread. ECEF positions are metres.

+ (simd_double3)ecefPositionWithLongitudeDegrees:(double)longitudeDegrees
                                  latitudeDegrees:(double)latitudeDegrees
                           ellipsoidHeightMeters:(double)ellipsoidHeightMeters
    NS_SWIFT_NAME(ecefPosition(longitudeDegrees:latitudeDegrees:ellipsoidHeightMeters:));
/// NaN in all three fields at the Earth's centre, where there is no answer.
+ (CesiumCartographic)cartographicOfEcefPosition:(simd_double3)ecefPosition
    NS_SWIFT_NAME(cartographic(ecefPosition:));
/// Local -> ECEF for the tangent frame at a point: X east, Y geodetic up, Z south.
+ (simd_double4x4)ecefFromLocalHorizontalWithOrigin:(simd_double3)ecefPosition
    NS_SWIFT_NAME(ecefFromLocalHorizontal(origin:));
/// Height of the EGM96 geoid, which is mean sea level, above the ellipsoid.
+ (double)egm96GeoidHeightMetersAtLongitudeDegrees:(double)longitudeDegrees
                                   latitudeDegrees:(double)latitudeDegrees
    NS_SWIFT_NAME(egm96GeoidHeightMeters(longitudeDegrees:latitudeDegrees:));

// MARK: Tiles
//
// The tileset and everything belonging to the running session live in plain
// globals with no locks, and `updateTiles` drains Cesium's main-thread task
// queue, so these methods are main-thread-only by construction.
// `NS_SWIFT_UI_ACTOR` states that to Swift so the compiler checks it, and marks
// the callbacks as what they are: both run on the main queue, through
// `dispatch_async`.

/// `onPrepareTile` hands over a loaded tile's primitives, and Cesium then waits
/// for `finishPreparingTile` before it may select that tile. `onTileFreed`
/// says Cesium has unloaded one.
+ (void)startTilesWithAPIKey:(NSString *)apiKey
                    settings:(CesiumTileSelectionSettings)settings
               onPrepareTile:(void (^ NS_SWIFT_UI_ACTOR)(uint64_t tileIdentifier, NSArray<CesiumPrimitivePayload *> *primitives))onPrepareTile
                 onTileFreed:(void (^ NS_SWIFT_UI_ACTOR)(uint64_t tileIdentifier))onTileFreed
    NS_SWIFT_NAME(startTiles(apiKey:settings:onPrepareTile:onTileFreed:)) NS_SWIFT_UI_ACTOR;
/// Selects tiles for one frame and starts whatever loads that needs. The camera
/// is the wearer's head in ECEF; direction and up need not be unit length or
/// exactly perpendicular.
///
/// Returns the identifiers of every tile to draw, or nil while any selected
/// tile is still loading: until then the previous selection is the one without
/// holes in it.
+ (nullable NSArray<NSNumber *> *)updateTilesWithCameraPosition:(simd_double3)ecefPosition
                                                      direction:(simd_double3)ecefDirection
                                                             up:(simd_double3)ecefUp
                                                      deltaTime:(double)deltaTime
    NS_SWIFT_NAME(updateTiles(cameraPosition:direction:up:deltaTime:)) NS_SWIFT_UI_ACTOR;
/// Answers one `onPrepareTile`. Deliberately not main-actor: it takes a mutex
/// and resolves a Cesium promise, both safe from any thread.
+ (void)finishPreparingTile:(uint64_t)tileIdentifier succeeded:(BOOL)succeeded;
/// The credits for the tiles the last update selected, most used first, which
/// is the order Google asks for. Empty before the first update.
@property (class, nonatomic, readonly) NSString *attribution NS_SWIFT_UI_ACTOR;
/// Casts a ray along geodetic down from `ecefPosition` against tiles already
/// loaded, preferring the most detailed. It loads nothing, so it costs no
/// network or RealityKit work, and anything above the point never counts.
+ (CesiumGroundSample)groundBelowEcefPosition:(simd_double3)ecefPosition
    NS_SWIFT_NAME(groundBelow(ecefPosition:)) NS_SWIFT_UI_ACTOR;
/// Seconds since Google last refused a request for coming too fast (HTTP 429),
/// or infinity if it never has. Reads an atomic, so safe from any thread.
@property (class, nonatomic, readonly) double secondsSinceRateLimit;
+ (void)stopTiles NS_SWIFT_UI_ACTOR;

// MARK: Test seams
//
// Two internal steps that have no public route in.

+ (NSString *)decoratedGoogleURLForTesting:(NSString *)url apiKey:(NSString *)apiKey;
/// A glTF texture coordinate put through `KHR_texture_transform` and then
/// converted to RealityKit's convention, as the importer does it.
+ (simd_double2)realityKitTextureCoordinateForTestingWithUV:(simd_double2)uv
                                                     offset:(simd_double2)offset
                                                      scale:(simd_double2)scale
                                                   rotation:(double)rotation
    NS_SWIFT_NAME(realityKitTextureCoordinateForTesting(uv:offset:scale:rotation:));

@end

NS_ASSUME_NONNULL_END
