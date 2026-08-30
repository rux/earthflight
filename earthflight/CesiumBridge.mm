#import "CesiumBridge.h"

#include <CesiumGeospatial/Cartographic.h>
#include <CesiumGeospatial/Ellipsoid.h>

#include <cmath>
#include <optional>

@implementation CesiumBridge

+ (NSString *)runSmokeTest {
    const CesiumGeospatial::Cartographic cartographic =
        CesiumGeospatial::Cartographic::fromDegrees(0.0, 0.0, 0.0);
    const glm::dvec3 ecef =
        CesiumGeospatial::Ellipsoid::WGS84.cartographicToCartesian(cartographic);

    const bool isCorrect =
        std::abs(ecef.x - 6378137.0) < 0.001 &&
        std::abs(ecef.y) < 0.001 &&
        std::abs(ecef.z) < 0.001;

    return [NSString stringWithFormat:
        @"Cesium Native smoke test: %@\nWGS84 ECEF: %.3f, %.3f, %.3f",
        isCorrect ? @"OK" : @"FAILED",
        ecef.x,
        ecef.y,
        ecef.z
    ];
}

+ (NSString *)runCartographicRoundTripSmokeTest {
    // This exercises Cesium's inverse WGS84 conversion and its std::optional
    // result across the Objective-C++ boundary.
    const CesiumGeospatial::Cartographic original =
        CesiumGeospatial::Cartographic::fromDegrees(-0.1278, 51.5074, 1'000.0);
    const glm::dvec3 ecef =
        CesiumGeospatial::Ellipsoid::WGS84.cartographicToCartesian(original);
    const std::optional<CesiumGeospatial::Cartographic> recovered =
        CesiumGeospatial::Ellipsoid::WGS84.cartesianToCartographic(ecef);

    const bool isCorrect =
        recovered &&
        std::abs(recovered->longitude - original.longitude) < 1e-12 &&
        std::abs(recovered->latitude - original.latitude) < 1e-12 &&
        std::abs(recovered->height - original.height) < 0.001;

    return isCorrect
        ? @"Cesium Native cartographic round-trip: OK"
        : @"Cesium Native cartographic round-trip: FAILED";
}

@end
