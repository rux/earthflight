#import "CesiumBridge.h"

#include <Cesium3DTilesSelection/IPrepareRendererResources.h>
#include <Cesium3DTilesContent/registerAllTileContentTypes.h>
#include <Cesium3DTilesSelection/Tileset.h>
#include <Cesium3DTilesSelection/TilesetExternals.h>
#include <Cesium3DTilesSelection/ViewState.h>
#include <CesiumAsync/IAssetAccessor.h>
#include <CesiumAsync/IAssetRequest.h>
#include <CesiumAsync/IAssetResponse.h>
#include <CesiumAsync/ITaskProcessor.h>
#include <CesiumGeospatial/Cartographic.h>
#include <CesiumGeospatial/Ellipsoid.h>
#include <CesiumGeospatial/GlobeTransforms.h>

#include <cmath>
#include <dispatch/dispatch.h>
#include <glm/geometric.hpp>
#include <optional>
#include <spdlog/sinks/null_sink.h>
#include <spdlog/sinks/callback_sink.h>
#include <variant>

namespace {

class DispatchTaskProcessor final : public CesiumAsync::ITaskProcessor {
public:
    void startTask(std::function<void()> task) override {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ task(); });
    }
};

std::string decorateGoogleURL(const std::string& url, NSString *apiKey);

std::shared_ptr<spdlog::logger> makeSanitizedCesiumLogger() {
    auto logger = spdlog::callback_logger_mt("EarthflightCesium", [](const spdlog::details::log_msg& message) {
        std::string text(message.payload.data(), message.payload.size());
        size_t key = text.find("key=");
        while (key != std::string::npos) {
            size_t end = text.find_first_of("&`' \n", key);
            text.replace(key + 4, end == std::string::npos ? std::string::npos : end - key - 4, "REDACTED");
            key = text.find("key=", key + 12);
        }
        NSLog(@"Cesium: %@", [NSString stringWithUTF8String:text.c_str()]);
    });
    logger->set_level(spdlog::level::warn);
    return logger;
}

class AppleAssetResponse final : public CesiumAsync::IAssetResponse {
public:
    AppleAssetResponse(NSHTTPURLResponse *response, NSData *data) {
        status_ = static_cast<uint16_t>(response.statusCode);
        contentType_ = response.MIMEType.UTF8String ?: "";
        for (id key in response.allHeaderFields) {
            headers_.emplace([key description].UTF8String, [[response.allHeaderFields objectForKey:key] description].UTF8String);
        }
        const std::byte *first = reinterpret_cast<const std::byte *>(data.bytes);
        data_.assign(first, first + data.length);
    }
    uint16_t statusCode() const override { return status_; }
    std::string contentType() const override { return contentType_; }
    const CesiumAsync::HttpHeaders& headers() const override { return headers_; }
    std::span<const std::byte> data() const override { return data_; }
private:
    uint16_t status_ = 0;
    std::string contentType_;
    CesiumAsync::HttpHeaders headers_;
    std::vector<std::byte> data_;
};

class AppleAssetRequest final : public CesiumAsync::IAssetRequest {
public:
    AppleAssetRequest(std::string method, std::string url, CesiumAsync::HttpHeaders headers)
        : method_(std::move(method)), url_(std::move(url)), headers_(std::move(headers)) {}
    const std::string& method() const override { return method_; }
    const std::string& url() const override { return url_; }
    const CesiumAsync::HttpHeaders& headers() const override { return headers_; }
    const CesiumAsync::IAssetResponse* response() const override { return response_.get(); }
    void setResponse(std::shared_ptr<AppleAssetResponse> response) { response_ = std::move(response); }
private:
    std::string method_, url_;
    CesiumAsync::HttpHeaders headers_;
    std::shared_ptr<AppleAssetResponse> response_;
};

class AppleAssetAccessor final : public CesiumAsync::IAssetAccessor {
public:
    CesiumAsync::Future<std::shared_ptr<CesiumAsync::IAssetRequest>> get(
        const CesiumAsync::AsyncSystem& asyncSystem, const std::string& url,
        const std::vector<THeader>& headers) override {
        return request(asyncSystem, "GET", url, headers, {});
    }

    CesiumAsync::Future<std::shared_ptr<CesiumAsync::IAssetRequest>> request(
        const CesiumAsync::AsyncSystem& asyncSystem, const std::string& verb, const std::string& url,
        const std::vector<THeader>& headers, const std::span<const std::byte>& payload) override {
        auto promise = asyncSystem.createPromise<std::shared_ptr<CesiumAsync::IAssetRequest>>();
        auto future = promise.getFuture();
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]]];
        request.HTTPMethod = [NSString stringWithUTF8String:verb.c_str()];
        CesiumAsync::HttpHeaders requestHeaders;
        for (const THeader& header : headers) {
            [request setValue:[NSString stringWithUTF8String:header.second.c_str()] forHTTPHeaderField:[NSString stringWithUTF8String:header.first.c_str()]];
            requestHeaders.emplace(header.first, header.second);
        }
        if (!payload.empty()) request.HTTPBody = [NSData dataWithBytes:payload.data() length:payload.size()];
        auto assetRequest = std::make_shared<AppleAssetRequest>(verb, url, std::move(requestHeaders));
        [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (!http) {
                NSLog(@"Google tile request failed: domain=%@ code=%ld", error.domain ?: @"unknown", (long)error.code);
            } else if (http.statusCode >= 400) {
                NSLog(@"Google tile request failed: HTTP %ld (%lu bytes)", (long)http.statusCode, (unsigned long)data.length);
            } else {
                NSLog(@"Google tile request: HTTP %ld %@ (%lu bytes)",
                      (long)http.statusCode, http.MIMEType ?: @"unknown", (unsigned long)data.length);
                if ([http.MIMEType isEqualToString:@"model/gltf-binary"] && data.length >= 4) {
                    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
                    NSLog(@"Google GLB header: %02X %02X %02X %02X", bytes[0], bytes[1], bytes[2], bytes[3]);
                }
            }
            assetRequest->setResponse(std::make_shared<AppleAssetResponse>(http ?: [[NSHTTPURLResponse alloc] init], data ?: [NSData data]));
            promise.resolve(assetRequest);
        }].resume;
        return future;
    }
    void tick() noexcept override {}
};

class GoogleAssetAccessor final : public CesiumAsync::IAssetAccessor {
public:
    GoogleAssetAccessor(std::shared_ptr<CesiumAsync::IAssetAccessor> accessor, NSString *apiKey)
        : accessor_(std::move(accessor)), apiKey_([apiKey copy]) {}

    CesiumAsync::Future<std::shared_ptr<CesiumAsync::IAssetRequest>> get(
        const CesiumAsync::AsyncSystem& asyncSystem, const std::string& url,
        const std::vector<THeader>& headers) override {
        return accessor_->get(asyncSystem, googleURL(url), headers);
    }

    CesiumAsync::Future<std::shared_ptr<CesiumAsync::IAssetRequest>> request(
        const CesiumAsync::AsyncSystem& asyncSystem, const std::string& verb,
        const std::string& url, const std::vector<THeader>& headers,
        const std::span<const std::byte>& payload) override {
        return accessor_->request(asyncSystem, verb, googleURL(url), headers, payload);
    }

    void tick() noexcept override { accessor_->tick(); }

private:
    std::string googleURL(const std::string& url) const {
        return decorateGoogleURL(url, apiKey_);
    }

    std::shared_ptr<CesiumAsync::IAssetAccessor> accessor_;
    NSString *apiKey_;
};

std::string decorateGoogleURL(const std::string& url, NSString *apiKey) {
    @autoreleasepool {
        NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithUTF8String:url.c_str()]];
        if (![[components.host lowercaseString] isEqualToString:@"tile.googleapis.com"]) return url;
        for (NSURLQueryItem *item in components.queryItems ?: @[]) {
            if ([item.name isEqualToString:@"key"]) return url;
        }
        NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
        [items addObject:[NSURLQueryItem queryItemWithName:@"key" value:apiKey]];
        components.queryItems = items;
        return components.URL.absoluteString.UTF8String;
    }
}

class StaticRendererPreparation final : public Cesium3DTilesSelection::IPrepareRendererResources {
public:
    CesiumAsync::Future<Cesium3DTilesSelection::TileLoadResultAndRenderResources> prepareInLoadThread(
        const CesiumAsync::AsyncSystem& asyncSystem, Cesium3DTilesSelection::TileLoadResult&& result,
        const glm::dmat4&, const std::any&) override {
        if (result.state == Cesium3DTilesSelection::TileLoadResultState::Success && std::holds_alternative<CesiumGltf::Model>(result.contentKind)) {
            const CesiumGltf::Model& model = std::get<CesiumGltf::Model>(result.contentKind);
            NSLog(@"Google glTF load-thread: meshes=%zu images=%zu extensions=%zu",
                  model.meshes.size(), model.images.size(), model.extensionsUsed.size());
            if (!model.meshes.empty() && !model.meshes.front().primitives.empty()) {
                const CesiumGltf::MeshPrimitive& primitive = model.meshes.front().primitives.front();
                std::string attributes;
                for (const auto& [semantic, _] : primitive.attributes) {
                    attributes += semantic + " ";
                }
                NSLog(@"Google primitive: mode=%d indices=%d material=%d attributes=%@",
                      primitive.mode, primitive.indices, primitive.material,
                      [NSString stringWithUTF8String:attributes.c_str()]);
            }
            if (!model.images.empty() && model.images.front().pAsset) {
                const CesiumImage::ImageAsset& image = *model.images.front().pAsset;
                NSLog(@"Google image: %dx%d channels=%d bytesPerChannel=%d",
                      image.width, image.height, image.channels, image.bytesPerChannel);
            }
        }
        Cesium3DTilesSelection::TileLoadResultAndRenderResources prepared{std::move(result), nullptr};
        return asyncSystem.createResolvedFuture(std::move(prepared));
    }

    void* prepareInMainThread(Cesium3DTilesSelection::Tile&, void*) override {
        NSLog(@"Google glTF main-thread preparation reached.");
        return nullptr;
    }
    void free(Cesium3DTilesSelection::Tile&, void*, void*) noexcept override {}
    void* prepareRasterInLoadThread(CesiumImage::ImageAsset&, const std::any&) override { return nullptr; }
    void* prepareRasterInMainThread(CesiumRasterOverlays::RasterOverlayTile&, void*) override { return nullptr; }
    void freeRaster(const CesiumRasterOverlays::RasterOverlayTile&, void*, void*) noexcept override {}
    void attachRasterInMainThread(const Cesium3DTilesSelection::Tile&, int32_t, const CesiumRasterOverlays::RasterOverlayTile&, void*, const glm::dvec2&, const glm::dvec2&) override {}
    void detachRasterInMainThread(const Cesium3DTilesSelection::Tile&, int32_t, const CesiumRasterOverlays::RasterOverlayTile&, void*) noexcept override {}
};

std::unique_ptr<Cesium3DTilesSelection::Tileset> tileset;

Cesium3DTilesSelection::ViewState makeStaticLondonView() {
    const auto london = CesiumGeospatial::Cartographic::fromDegrees(-0.1278, 51.5074, 100.0);
    const glm::dvec3 position = CesiumGeospatial::Ellipsoid::WGS84.cartographicToCartesian(london);
    const glm::dmat4 enu = CesiumGeospatial::GlobeTransforms::eastNorthUpToFixedFrame(position);
    const glm::dvec3 east(enu[0]), north(enu[1]), up(enu[2]);
    const glm::dvec3 direction = glm::normalize(-0.2 * east + 0.55 * north - 0.81 * up);
    const glm::dvec3 cameraUp = glm::normalize(glm::cross(glm::cross(direction, north), direction));
    return {position, direction, cameraUp, {2048.0, 2048.0}, 1.57, 1.22};
}

} // namespace

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
        CesiumGeospatial::Cartographic::fromDegrees(-0.1278, 51.5074, 100.0);
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

+ (NSString *)decoratedGoogleURLForTesting:(NSString *)url apiKey:(NSString *)apiKey {
    return [NSString stringWithUTF8String:decorateGoogleURL(url.UTF8String, apiKey).c_str()];
}

+ (NSString *)runLondonLocalFrameSmokeTest {
    // ECEF is double precision. The local ENU origin must map exactly to zero before
    // any eventual conversion to RealityKit's metre-scale Float transforms.
    const auto london = CesiumGeospatial::Cartographic::fromDegrees(-0.1278, 51.5074, 1000.0);
    const glm::dvec3 origin = CesiumGeospatial::Ellipsoid::WGS84.cartographicToCartesian(london);
    const glm::dmat4 enuToEcef = CesiumGeospatial::GlobeTransforms::eastNorthUpToFixedFrame(origin);
    const glm::dvec3 localOrigin = glm::dvec3(glm::inverse(enuToEcef) * glm::dvec4(origin, 1.0));
    const glm::dvec3 east = glm::normalize(glm::dvec3(enuToEcef[0]));
    const glm::dvec3 localEast = glm::dvec3(glm::inverse(enuToEcef) * glm::dvec4(origin + east * 100.0, 1.0));
    const bool isCorrect = glm::length(localOrigin) < 1e-6 &&
        std::abs(localEast.x - 100.0) < 1e-6 &&
        std::abs(localEast.y) < 1e-6 &&
        std::abs(localEast.z) < 1e-6;
    return isCorrect ? @"London local ENU frame: OK" : @"London local ENU frame: FAILED";
}

+ (void)startStaticLondonTilesWithAPIKey:(NSString *)apiKey {
    if (apiKey.length == 0) {
        NSLog(@"Google Maps API key is empty. Add it to ignored Secrets.xcconfig.");
        return;
    }
    Cesium3DTilesContent::registerAllTileContentTypes();
    Cesium3DTilesSelection::TilesetExternals externals{
        nullptr,
        nullptr,
        CesiumAsync::AsyncSystem(std::make_shared<DispatchTaskProcessor>())
    };
    externals.pAssetAccessor = std::make_shared<GoogleAssetAccessor>(std::make_shared<AppleAssetAccessor>(), apiKey);
    externals.pPrepareRendererResources = std::make_shared<StaticRendererPreparation>();
    externals.pLogger = makeSanitizedCesiumLogger();
    Cesium3DTilesSelection::TilesetOptions options;
    options.maximumSimultaneousTileLoads = 2;
    options.preloadAncestors = false;
    options.preloadSiblings = false;
    options.maximumScreenSpaceError = 64.0;
    tileset = std::make_unique<Cesium3DTilesSelection::Tileset>(
        externals, "https://tile.googleapis.com/v1/3dtiles/root.json", options);
    NSLog(@"Google London tileset started.");
}

+ (void)updateStaticLondonTiles {
    if (!tileset) return;
    tileset->getAsyncSystem().dispatchMainThreadTasks();
    tileset->updateViewGroup(tileset->getDefaultViewGroup(), {makeStaticLondonView()}, 1.0f / 60.0f);
    tileset->loadTiles();
}

@end
