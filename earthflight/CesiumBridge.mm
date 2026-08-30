#import "CesiumBridge.h"

#include <CesiumGeospatial/Cartographic.h>
#include <CesiumGeospatial/Ellipsoid.h>

#include <cmath>

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

@end
