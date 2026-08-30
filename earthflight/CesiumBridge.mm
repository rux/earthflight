#import "CesiumBridge.h"

#include <Cesium3DTilesSelection/IPrepareRendererResources.h>
#include <Cesium3DTilesContent/registerAllTileContentTypes.h>
#include <Cesium3DTilesSelection/Tileset.h>
#include <Cesium3DTilesSelection/TilesetExternals.h>
#include <Cesium3DTilesSelection/TileContent.h>
#include <Cesium3DTilesSelection/ViewState.h>
#include <CesiumGltf/AccessorView.h>
#include <CesiumGltfContent/GltfUtilities.h>
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

@interface CesiumPrimitivePayload ()
@property (nonatomic, readwrite) NSData *positions;
@property (nonatomic, readwrite) NSData *textureCoordinates;
@property (nonatomic, readwrite) NSData *indices;
@property (nonatomic, readwrite) NSData *rgbaImage;
@property (nonatomic, readwrite) NSInteger imageWidth;
@property (nonatomic, readwrite) NSInteger imageHeight;
@property (nonatomic, readwrite) BOOL doubleSided;
@end

@implementation CesiumPrimitivePayload
@end

namespace {

void (^tileReady)(NSString *, NSArray<CesiumPrimitivePayload *> *);
void (^tileFreed)(NSString *);

struct TileRenderResources {
    __strong NSString *identifier;
    __strong NSArray<CesiumPrimitivePayload *> *primitives;
};

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
        // Google URLs carry the private key. Keep only the useful status/error,
        // never the request path or query string, in development diagnostics.
        size_t url = text.find("https://tile.googleapis.com/");
        while (url != std::string::npos) {
            size_t end = text.find_first_of("`' \n", url);
            text.replace(url, end == std::string::npos ? std::string::npos : end - url, "Google tile URL omitted");
            url = text.find("https://tile.googleapis.com/", url + 23);
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
        const glm::dmat4& tileTransform, const std::any&) override {
        auto *resources = new TileRenderResources{};
        if (result.state == Cesium3DTilesSelection::TileLoadResultState::Success && std::holds_alternative<CesiumGltf::Model>(result.contentKind)) {
            CesiumGltf::Model& model = std::get<CesiumGltf::Model>(result.contentKind);
            NSMutableArray<CesiumPrimitivePayload *> *payloads = [NSMutableArray array];
            // Fixed Milestone 4 local origin: London at 250 m WGS84 ellipsoid height.
            const auto london = CesiumGeospatial::Cartographic::fromDegrees(-0.1278, 51.5074, 250.0);
            const glm::dvec3 origin = CesiumGeospatial::Ellipsoid::WGS84.cartographicToCartesian(london);
            const glm::dmat4 ecefToEnu = glm::inverse(CesiumGeospatial::GlobeTransforms::eastNorthUpToFixedFrame(origin));
            // glTF vertex data is relative to the model's CESIUM_RTC centre. Cesium keeps
            // that centre in the decoded model extension rather than folding it into the
            // 3D Tiles tile transform passed to this callback.
            const glm::dmat4 modelToEcef = CesiumGltfContent::GltfUtilities::applyGltfUpAxisTransform(
                model,
                CesiumGltfContent::GltfUtilities::applyRtcCenter(model, tileTransform));
            model.forEachPrimitiveInScene(-1, [&](CesiumGltf::Model& gltf, CesiumGltf::Node&, CesiumGltf::Mesh&, CesiumGltf::MeshPrimitive& primitive, const glm::dmat4& nodeTransform) {
                if (primitive.mode != CesiumGltf::MeshPrimitive::Mode::TRIANGLES) return;
                const auto positionIt = primitive.attributes.find("POSITION");
                if (positionIt == primitive.attributes.end() || primitive.indices < 0 || primitive.material < 0) return;
                const CesiumGltf::Material *material = CesiumGltf::Model::getSafe(&gltf.materials, primitive.material);
                if (!material || !material->pbrMetallicRoughness || !material->pbrMetallicRoughness->baseColorTexture) return;
                const CesiumGltf::TextureInfo& baseColorTexture = *material->pbrMetallicRoughness->baseColorTexture;
                // glTF chooses the UV set on TextureInfo. Google tiles observed so
                // far use TEXCOORD_0, but selecting it here was an unsupported
                // assumption and can sample deliberately unused black atlas regions.
                const std::string textureCoordinateAttribute = "TEXCOORD_" + std::to_string(baseColorTexture.texCoord);
                const auto uvIt = primitive.attributes.find(textureCoordinateAttribute);
                if (uvIt == primitive.attributes.end()) return;
                CesiumGltf::AccessorView<glm::vec3> positions(gltf, positionIt->second);
                CesiumGltf::AccessorView<glm::vec2> uvs(gltf, uvIt->second);
                if (positions.status() != CesiumGltf::AccessorViewStatus::Valid || uvs.status() != CesiumGltf::AccessorViewStatus::Valid || positions.size() != uvs.size()) return;
                const CesiumGltf::Texture *texture = CesiumGltf::Model::getSafe(&gltf.textures, baseColorTexture.index);
                const CesiumGltf::Image *image = texture ? CesiumGltf::Model::getSafe(&gltf.images, texture->source) : nullptr;
                if (!image || !image->pAsset || image->pAsset->channels != 4 || image->pAsset->bytesPerChannel != 1) return;
                NSMutableData *positionData = [NSMutableData dataWithLength:positions.size() * sizeof(float) * 3];
                NSMutableData *uvData = [NSMutableData dataWithLength:uvs.size() * sizeof(float) * 2];
                float *outPositions = static_cast<float *>(positionData.mutableBytes);
                float *outUVs = static_cast<float *>(uvData.mutableBytes);
                for (int64_t i = 0; i < positions.size(); ++i) {
                    const glm::dvec4 ecef = modelToEcef * nodeTransform * glm::dvec4(positions[i], 1.0);
                    const glm::dvec3 enu = glm::dvec3(ecefToEnu * ecef);
                    // ENU (+east,+north,+up) maps to RealityKit (+x,+y,-z), preserving right-handed local space.
                    outPositions[i * 3] = static_cast<float>(enu.x);
                    outPositions[i * 3 + 1] = static_cast<float>(enu.z);
                    outPositions[i * 3 + 2] = static_cast<float>(-enu.y);
                    outUVs[i * 2] = uvs[i].x;
                    outUVs[i * 2 + 1] = uvs[i].y;
                }
                NSMutableData *indexData = [NSMutableData data];
                const CesiumGltf::Accessor *indexAccessor = CesiumGltf::Model::getSafe(&gltf.accessors, primitive.indices);
                if (!indexAccessor) return;
                auto appendIndices = [&](auto view) {
                    if (view.status() != CesiumGltf::AccessorViewStatus::Valid) return false;
                    for (int64_t i = 0; i < view.size(); ++i) { uint32_t value = static_cast<uint32_t>(view[i]); [indexData appendBytes:&value length:sizeof(value)]; }
                    return true;
                };
                bool validIndices = false;
                if (indexAccessor->componentType == CesiumGltf::Accessor::ComponentType::UNSIGNED_BYTE) validIndices = appendIndices(CesiumGltf::AccessorView<uint8_t>(gltf, primitive.indices));
                if (indexAccessor->componentType == CesiumGltf::Accessor::ComponentType::UNSIGNED_SHORT) validIndices = appendIndices(CesiumGltf::AccessorView<uint16_t>(gltf, primitive.indices));
                if (indexAccessor->componentType == CesiumGltf::Accessor::ComponentType::UNSIGNED_INT) validIndices = appendIndices(CesiumGltf::AccessorView<uint32_t>(gltf, primitive.indices));
                if (!validIndices) return;
                const uint32_t *outputIndices = static_cast<const uint32_t *>(indexData.bytes);
                const NSUInteger outputIndexCount = indexData.length / sizeof(uint32_t);
                uint32_t maximumIndex = 0;
                for (NSUInteger i = 0; i < outputIndexCount; ++i) {
                    maximumIndex = std::max(maximumIndex, outputIndices[i]);
                }
                if (maximumIndex >= positions.size()) {
                    return;
                }
                CesiumPrimitivePayload *payload = [CesiumPrimitivePayload new];
                payload.positions = positionData;
                payload.textureCoordinates = uvData;
                payload.indices = indexData;
                // Cesium may retain generated mip levels back-to-back in pixelData.
                // RealityKit's single .mip upload must receive exactly the full-resolution
                // image range, not the concatenated image asset.
                size_t imageByteOffset = 0;
                size_t imageByteLength = image->pAsset->pixelData.size();
                if (!image->pAsset->mipPositions.empty()) {
                    const CesiumImage::ImageAssetMipPosition& baseMip = image->pAsset->mipPositions.front();
                    imageByteOffset = baseMip.byteOffset;
                    imageByteLength = baseMip.byteSize;
                }
                const size_t expectedImageByteLength =
                    static_cast<size_t>(image->pAsset->width) *
                    static_cast<size_t>(image->pAsset->height) *
                    static_cast<size_t>(image->pAsset->channels) *
                    static_cast<size_t>(image->pAsset->bytesPerChannel);
                if (imageByteLength != expectedImageByteLength ||
                    imageByteOffset + imageByteLength > image->pAsset->pixelData.size()) return;
                payload.rgbaImage = [NSData dataWithBytes:image->pAsset->pixelData.data() + imageByteOffset length:imageByteLength];
                payload.imageWidth = image->pAsset->width;
                payload.imageHeight = image->pAsset->height;
                // glTF specifies culling per material. Do not force a culling mode:
                // Google tiles may legitimately contain both single- and double-sided surfaces.
                payload.doubleSided = material->doubleSided;
                [payloads addObject:payload];
            });
            resources->primitives = payloads;
        }
        Cesium3DTilesSelection::TileLoadResultAndRenderResources prepared{std::move(result), nullptr};
        prepared.pRenderResources = resources;
        return asyncSystem.createResolvedFuture(std::move(prepared));
    }

    void* prepareInMainThread(Cesium3DTilesSelection::Tile& tile, void* loadThreadResources) override {
        auto *resources = static_cast<TileRenderResources *>(loadThreadResources);
        resources->identifier = [NSString stringWithFormat:@"%p", &tile];
        return resources;
    }
    void free(Cesium3DTilesSelection::Tile&, void* loadThreadResources, void* mainThreadResources) noexcept override {
        auto *resources = static_cast<TileRenderResources *>(mainThreadResources ?: loadThreadResources);
        NSString *identifier = resources->identifier;
        if (identifier && tileFreed) {
            dispatch_async(dispatch_get_main_queue(), ^{ tileFreed(identifier); });
        }
        delete resources;
    }
    void* prepareRasterInLoadThread(CesiumImage::ImageAsset&, const std::any&) override { return nullptr; }
    void* prepareRasterInMainThread(CesiumRasterOverlays::RasterOverlayTile&, void*) override { return nullptr; }
    void freeRaster(const CesiumRasterOverlays::RasterOverlayTile&, void*, void*) noexcept override {}
    void attachRasterInMainThread(const Cesium3DTilesSelection::Tile&, int32_t, const CesiumRasterOverlays::RasterOverlayTile&, void*, const glm::dvec2&, const glm::dvec2&) override {}
    void detachRasterInMainThread(const Cesium3DTilesSelection::Tile&, int32_t, const CesiumRasterOverlays::RasterOverlayTile&, void*) noexcept override {}
};

std::unique_ptr<Cesium3DTilesSelection::Tileset> tileset;

Cesium3DTilesSelection::ViewState makeStaticLondonView() {
    const auto london = CesiumGeospatial::Cartographic::fromDegrees(-0.1278, 51.5074, 250.0);
    const glm::dvec3 position = CesiumGeospatial::Ellipsoid::WGS84.cartographicToCartesian(london);
    const glm::dmat4 enu = CesiumGeospatial::GlobeTransforms::eastNorthUpToFixedFrame(position);
    const glm::dvec3 east(enu[0]), north(enu[1]), up(enu[2]);
    // Fixed Milestone 4 proof view: nearly nadir so that the terrain directly
    // below the physical viewer remains inside Cesium's static selection frustum.
    // The small northward component keeps the initial London view usefully oblique.
    const glm::dvec3 direction = glm::normalize(-0.1 * east + 0.2 * north - 0.975 * up);
    const glm::dvec3 cameraUp = glm::normalize(glm::cross(glm::cross(direction, north), direction));
    // This is a fixed proof view, not the headset's LOD view. A moderate
    // virtual viewport keeps Google's renderer-request rate below its quota.
    return {position, direction, cameraUp, {1024.0, 1024.0}, 1.57, 1.22};
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
    [self startStaticLondonTilesWithAPIKey:apiKey onTileReady:nil];
}

+ (void)startStaticLondonTilesWithAPIKey:(NSString *)apiKey
                             onTileReady:(void (^)(NSString *tileIdentifier, NSArray<CesiumPrimitivePayload *> *primitives))onTileReady {
    [self startStaticLondonTilesWithAPIKey:apiKey onTileVisible:onTileReady onTileFreed:nil];
}

+ (void)startStaticLondonTilesWithAPIKey:(NSString *)apiKey
                           onTileVisible:(void (^)(NSString *tileIdentifier, NSArray<CesiumPrimitivePayload *> *primitives))onTileVisible
                              onTileFreed:(void (^)(NSString *tileIdentifier))onTileFreed {
    if (apiKey.length == 0) {
        NSLog(@"Google Maps API key is empty. Add it to ignored Secrets.xcconfig.");
        return;
    }
    tileReady = [onTileVisible copy];
    tileFreed = [onTileFreed copy];
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
    // This is a fixed, bounded London view. Four concurrent Google requests fill
    // its selected coverage promptly without introducing a persistent cache.
    options.maximumSimultaneousTileLoads = 4;
    options.preloadAncestors = false;
    options.preloadSiblings = false;
    // Milestone 4 prioritises recognisable London geometry over streaming range.
    // Four pixels is sufficient for the fixed proof view; the one-pixel/no-holes
    // experiment did not change the black source regions.
    options.maximumScreenSpaceError = 4.0;
    tileset = std::make_unique<Cesium3DTilesSelection::Tileset>(
        externals, "https://tile.googleapis.com/v1/3dtiles/root.json", options);
    NSLog(@"Google London tileset started.");
}

+ (void)updateStaticLondonTiles {
    if (!tileset) return;
    tileset->getAsyncSystem().dispatchMainThreadTasks();
    const Cesium3DTilesSelection::ViewUpdateResult& result =
        tileset->updateViewGroup(tileset->getDefaultViewGroup(), {makeStaticLondonView()}, 1.0f / 60.0f);
    for (const Cesium3DTilesSelection::Tile::ConstPointer& tile : result.tilesFadingOut) {
        const Cesium3DTilesSelection::TileRenderContent *content = tile->getContent().getRenderContent();
        auto *resources = content ? static_cast<TileRenderResources *>(content->getRenderResources()) : nullptr;
        if (resources && resources->identifier && tileFreed) tileFreed(resources->identifier);
    }
    for (const Cesium3DTilesSelection::Tile::ConstPointer& tile : result.tilesToRenderThisFrame) {
        const Cesium3DTilesSelection::TileRenderContent *content = tile->getContent().getRenderContent();
        auto *resources = content ? static_cast<TileRenderResources *>(content->getRenderResources()) : nullptr;
        if (resources && resources->identifier && resources->primitives.count > 0 && tileReady) {
            tileReady(resources->identifier, resources->primitives);
        }
    }
    tileset->loadTiles();
}

@end
