#import "CesiumBridge.h"

#include <Cesium3DTilesSelection/IPrepareRendererResources.h>
#include <Cesium3DTilesContent/registerAllTileContentTypes.h>
#include <Cesium3DTilesSelection/Tileset.h>
#include <Cesium3DTilesSelection/TilesetExternals.h>
#include <Cesium3DTilesSelection/TileContent.h>
#include <Cesium3DTilesSelection/ViewState.h>
#include <CesiumGltf/AccessorView.h>
#include <CesiumGltf/ExtensionKhrTextureTransform.h>
#include <CesiumGltf/KhrTextureTransform.h>
#include <CesiumGltfContent/GltfUtilities.h>
#include <CesiumAsync/IAssetAccessor.h>
#include <CesiumAsync/IAssetRequest.h>
#include <CesiumAsync/IAssetResponse.h>
#include <CesiumAsync/ITaskProcessor.h>
#include <CesiumGeospatial/Cartographic.h>
#include <CesiumGeospatial/Ellipsoid.h>
#include <CesiumGeospatial/EarthGravitationalModel1996Grid.h>
#include <CesiumGeospatial/LocalHorizontalCoordinateSystem.h>
#include <CesiumUtility/CreditSystem.h>

#include <algorithm>
#include <cmath>
#include <dispatch/dispatch.h>
#include <glm/geometric.hpp>
#include <glm/gtc/matrix_inverse.hpp>
#include <limits>
#include <optional>
#include <spdlog/sinks/null_sink.h>
#include <spdlog/sinks/callback_sink.h>
#include <type_traits>
#include <unordered_set>
#include <variant>

#include <cstddef>
#include <memory>

@interface CesiumPrimitivePayload ()
@property (nonatomic, readwrite) NSData *positions;
@property (nonatomic, readwrite) NSData *textureCoordinates;
@property (nonatomic, readwrite) NSData *indices;
@property (nonatomic, readwrite) NSData *rgbaImage;
@property (nonatomic, readwrite) NSInteger imageWidth;
@property (nonatomic, readwrite) NSInteger imageHeight;
@property (nonatomic, readwrite) NSInteger samplerWrapS;
@property (nonatomic, readwrite) NSInteger samplerWrapT;
@property (nonatomic, readwrite) NSInteger samplerMinFilter;
@property (nonatomic, readwrite) NSInteger samplerMagFilter;
@property (nonatomic, readwrite) BOOL doubleSided;
@property (nonatomic, readwrite) simd_double4x4 ecefFromPrimitiveLocal;
@end

@implementation CesiumPrimitivePayload
@end

namespace {

void (^tileReady)(NSString *, NSArray<CesiumPrimitivePayload *> *);
void (^tileHidden)(NSString *);
void (^tileFreed)(NSString *);
void (^attributionChanged)(NSString *);
std::shared_ptr<CesiumUtility::CreditSystem> creditSystem;
std::string lastAttribution;
bool lodTransitionsAreEnabled = false;
bool pauseLodTransitionsForPendingInstall = false;
std::unordered_set<std::string> realityKitInstalledTiles;
std::optional<CesiumGeospatial::EarthGravitationalModel1996Grid> egm96Grid;

const CesiumGeospatial::EarthGravitationalModel1996Grid& loadedEGM96Grid() {
    if (!egm96Grid) {
        NSURL *url = [[NSBundle bundleForClass:[CesiumBridge class]] URLForResource:@"WW15MGH" withExtension:@"DAC"];
        NSCAssert(url != nil, @"WW15MGH.DAC must be bundled with Earthflight");
        NSData *data = [NSData dataWithContentsOfURL:url];
        NSCAssert(data != nil, @"Earthflight could not load bundled WW15MGH.DAC");
        const auto *bytes = static_cast<const std::byte *>(data.bytes);
        egm96Grid = CesiumGeospatial::EarthGravitationalModel1996Grid::fromBuffer(
            std::span<const std::byte>(bytes, data.length)
        );
        NSCAssert(egm96Grid.has_value(), @"Bundled WW15MGH.DAC is malformed");
    }
    return *egm96Grid;
}

struct TileRenderResources {
    __strong NSString *identifier;
    __strong NSArray<CesiumPrimitivePayload *> *primitives;
};

CesiumGeospatial::LocalHorizontalCoordinateSystem makeRealityKitLocalFrame(
    const glm::dvec3& originEcef) {
    // Right-handed, metre-scale RealityKit convention: X=east, Y=geodetic up,
    // Z=south (-north). Cesium owns the WGS84 tangent-frame construction.
    return CesiumGeospatial::LocalHorizontalCoordinateSystem(
        originEcef,
        CesiumGeospatial::LocalDirection::East,
        CesiumGeospatial::LocalDirection::Up,
        CesiumGeospatial::LocalDirection::South,
        1.0,
        CesiumGeospatial::Ellipsoid::WGS84);
}

simd_double3 simdVectorFromGlm(const glm::dvec3& value) {
    return simd_make_double3(value.x, value.y, value.z);
}

glm::dvec3 glmVectorFromSimd(simd_double3 value) {
    return {value.x, value.y, value.z};
}

simd_double4x4 simdMatrixFromGlm(const glm::dmat4& matrix) {
    simd_double4x4 result;
    for (int column = 0; column < 4; ++column) {
        for (int row = 0; row < 4; ++row) {
            result.columns[column][row] = matrix[column][row];
        }
    }
    return result;
}

class DispatchTaskProcessor final : public CesiumAsync::ITaskProcessor {
public:
    void startTask(std::function<void()> task) override {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ task(); });
    }
};

std::string decorateGoogleURL(const std::string& url, NSString *apiKey);

template <typename T> double normalizedComponent(T value) {
    if constexpr (std::is_floating_point_v<T>) {
        return static_cast<double>(value);
    } else if constexpr (std::is_unsigned_v<T>) {
        return static_cast<double>(value) / static_cast<double>(std::numeric_limits<T>::max());
    } else {
        return std::max(
            static_cast<double>(value) / static_cast<double>(std::numeric_limits<T>::max()),
            -1.0);
    }
}

template <typename T>
bool decodeUVs(
    const CesiumGltf::Model& model,
    int32_t accessorIndex,
    bool normalized,
    std::vector<glm::dvec2>& output) {
    CesiumGltf::AccessorView<CesiumGltf::AccessorTypes::VEC2<T>> view(model, accessorIndex);
    if (view.status() != CesiumGltf::AccessorViewStatus::Valid) return false;
    output.resize(static_cast<size_t>(view.size()));
    for (int64_t i = 0; i < view.size(); ++i) {
        const auto& value = view[i].value;
        if (normalized) {
            output[static_cast<size_t>(i)] = glm::dvec2(
                normalizedComponent(value[0]),
                normalizedComponent(value[1]));
        } else {
            output[static_cast<size_t>(i)] = glm::dvec2(value[0], value[1]);
        }
    }
    return true;
}

bool decodeUVs(
    const CesiumGltf::Model& model,
    int32_t accessorIndex,
    std::vector<glm::dvec2>& output) {
    const CesiumGltf::Accessor *accessor = CesiumGltf::Model::getSafe(&model.accessors, accessorIndex);
    if (!accessor || accessor->type != CesiumGltf::Accessor::Type::VEC2) return false;
    switch (accessor->componentType) {
        case CesiumGltf::Accessor::ComponentType::BYTE:
            return decodeUVs<int8_t>(model, accessorIndex, accessor->normalized, output);
        case CesiumGltf::Accessor::ComponentType::UNSIGNED_BYTE:
            return decodeUVs<uint8_t>(model, accessorIndex, accessor->normalized, output);
        case CesiumGltf::Accessor::ComponentType::SHORT:
            return decodeUVs<int16_t>(model, accessorIndex, accessor->normalized, output);
        case CesiumGltf::Accessor::ComponentType::UNSIGNED_SHORT:
            return decodeUVs<uint16_t>(model, accessorIndex, accessor->normalized, output);
        case CesiumGltf::Accessor::ComponentType::FLOAT:
            return decodeUVs<float>(model, accessorIndex, false, output);
        default:
            return false;
    }
}

glm::dvec2 realityKitTextureCoordinate(const glm::dvec2& gltfTextureCoordinate) {
    // glTF defines (0, 0) at the upper-left of the image. RealityKit's
    // generated-mesh / built-in-material path uses the USD-style V convention.
    return {gltfTextureCoordinate.x, 1.0 - gltfTextureCoordinate.y};
}

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

class RendererPreparation final : public Cesium3DTilesSelection::IPrepareRendererResources {
public:
    CesiumAsync::Future<Cesium3DTilesSelection::TileLoadResultAndRenderResources> prepareInLoadThread(
        const CesiumAsync::AsyncSystem& asyncSystem, Cesium3DTilesSelection::TileLoadResult&& result,
        const glm::dmat4& tileTransform, const std::any&) override {
        auto *resources = new TileRenderResources{};
        if (result.state == Cesium3DTilesSelection::TileLoadResultState::Success && std::holds_alternative<CesiumGltf::Model>(result.contentKind)) {
            CesiumGltf::Model& model = std::get<CesiumGltf::Model>(result.contentKind);
            NSMutableArray<CesiumPrimitivePayload *> *payloads = [NSMutableArray array];
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
                const CesiumGltf::ExtensionKhrTextureTransform *textureTransformExtension =
                    baseColorTexture.getExtension<CesiumGltf::ExtensionKhrTextureTransform>();
                const CesiumGltf::KhrTextureTransform textureTransform = textureTransformExtension
                    ? CesiumGltf::KhrTextureTransform(*textureTransformExtension)
                    : CesiumGltf::KhrTextureTransform();
                // KHR_texture_transform may override TextureInfo.texCoord. Decode
                // the selected accessor according to its declared component type,
                // normalization, offsets, and stride before applying the transform.
                const int64_t effectiveTexCoord =
                    textureTransformExtension && textureTransformExtension->texCoord
                        ? *textureTransformExtension->texCoord
                        : baseColorTexture.texCoord;
                const std::string textureCoordinateAttribute =
                    "TEXCOORD_" + std::to_string(effectiveTexCoord);
                const auto uvIt = primitive.attributes.find(textureCoordinateAttribute);
                if (uvIt == primitive.attributes.end()) return;
                CesiumGltf::AccessorView<glm::vec3> positions(gltf, positionIt->second);
                std::vector<glm::dvec2> uvs;
                if (positions.status() != CesiumGltf::AccessorViewStatus::Valid ||
                    !decodeUVs(gltf, uvIt->second, uvs) ||
                    positions.size() == 0 ||
                    static_cast<size_t>(positions.size()) != uvs.size()) return;
                const CesiumGltf::Texture *texture = CesiumGltf::Model::getSafe(&gltf.textures, baseColorTexture.index);
                const CesiumGltf::Image *image = texture ? CesiumGltf::Model::getSafe(&gltf.images, texture->source) : nullptr;
                if (!image || !image->pAsset || image->pAsset->channels != 4 || image->pAsset->bytesPerChannel != 1) return;
                std::vector<glm::dvec3> ecefPositions(static_cast<size_t>(positions.size()));
                glm::dvec3 primitiveAnchorEcef(0.0);
                for (int64_t i = 0; i < positions.size(); ++i) {
                    const glm::dvec4 ecef =
                        modelToEcef * nodeTransform * glm::dvec4(positions[i], 1.0);
                    ecefPositions[static_cast<size_t>(i)] = glm::dvec3(ecef);
                    primitiveAnchorEcef += glm::dvec3(ecef);
                }
                primitiveAnchorEcef /= static_cast<double>(positions.size());
                // A coarse primitive can span enough globe that its arithmetic mean
                // approaches Earth centre. In that pathological case a real vertex is
                // a safer stable surface-near anchor than a non-geographic mean.
                if (glm::length(primitiveAnchorEcef) <
                    CesiumGeospatial::Ellipsoid::WGS84.getMinimumRadius() * 0.5) {
                    primitiveAnchorEcef = ecefPositions.front();
                }
                const CesiumGeospatial::LocalHorizontalCoordinateSystem primitiveFrame =
                    makeRealityKitLocalFrame(primitiveAnchorEcef);
                NSMutableData *positionData = [NSMutableData dataWithLength:positions.size() * sizeof(float) * 3];
                NSMutableData *uvData = [NSMutableData dataWithLength:uvs.size() * sizeof(float) * 2];
                float *outPositions = static_cast<float *>(positionData.mutableBytes);
                float *outUVs = static_cast<float *>(uvData.mutableBytes);
                for (int64_t i = 0; i < positions.size(); ++i) {
                    // Source vertices become ECEF in Double through the validated
                    // node/model/RTC/tile/up-axis order above. Cesium then reduces
                    // them to metres near this primitive before the only Float cast.
                    const glm::dvec3 primitiveLocal = primitiveFrame.ecefPositionToLocal(
                        ecefPositions[static_cast<size_t>(i)]);
                    outPositions[i * 3] = static_cast<float>(primitiveLocal.x);
                    outPositions[i * 3 + 1] = static_cast<float>(primitiveLocal.y);
                    outPositions[i * 3 + 2] = static_cast<float>(primitiveLocal.z);
                    const glm::dvec2 uv = textureTransformExtension
                        ? textureTransform.applyTransform(uvs[static_cast<size_t>(i)].x, uvs[static_cast<size_t>(i)].y)
                        : uvs[static_cast<size_t>(i)];
                    // Convert only after applying KHR_texture_transform because the
                    // extension itself is defined in glTF's upper-left UV space.
                    const glm::dvec2 realityKitUV = realityKitTextureCoordinate(uv);
                    outUVs[i * 2] = static_cast<float>(realityKitUV.x);
                    outUVs[i * 2 + 1] = static_cast<float>(realityKitUV.y);
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
                payload.ecefFromPrimitiveLocal = simdMatrixFromGlm(
                    primitiveFrame.getLocalToEcefTransformation());
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
                const CesiumGltf::Sampler *sampler =
                    CesiumGltf::Model::getSafe(&gltf.samplers, texture->sampler);
                payload.samplerWrapS = sampler
                    ? sampler->wrapS
                    : CesiumGltf::Sampler::WrapS::REPEAT;
                payload.samplerWrapT = sampler
                    ? sampler->wrapT
                    : CesiumGltf::Sampler::WrapT::REPEAT;
                payload.samplerMinFilter = sampler && sampler->minFilter
                    ? *sampler->minFilter
                    : CesiumGltf::Sampler::MinFilter::LINEAR_MIPMAP_LINEAR;
                payload.samplerMagFilter = sampler && sampler->magFilter
                    ? *sampler->magFilter
                    : CesiumGltf::Sampler::MagFilter::LINEAR;
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
            dispatch_async(dispatch_get_main_queue(), ^{
                realityKitInstalledTiles.erase(identifier.UTF8String);
                tileFreed(identifier);
            });
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

+ (NSArray<NSNumber *> *)realityKitTextureCoordinateForTestingWithU:(double)u
                                                                  v:(double)v
                                                            offsetU:(double)offsetU
                                                            offsetV:(double)offsetV
                                                             scaleU:(double)scaleU
                                                             scaleV:(double)scaleV
                                                           rotation:(double)rotation {
    CesiumGltf::ExtensionKhrTextureTransform extension;
    extension.offset = {offsetU, offsetV};
    extension.scale = {scaleU, scaleV};
    extension.rotation = rotation;
    const glm::dvec2 transformed = CesiumGltf::KhrTextureTransform(extension).applyTransform(u, v);
    const glm::dvec2 converted = realityKitTextureCoordinate(transformed);
    return @[@(converted.x), @(converted.y)];
}

+ (NSString *)runLocalHorizontalFrameSmokeTest {
    // Preserve the original local-frame smoke test at the accepted launch region,
    // now using the exact planetary X=east, Y=up, Z=south convention.
    const auto launch = CesiumGeospatial::Cartographic::fromDegrees(-0.1278, 51.5074, 1000.0);
    const glm::dvec3 origin =
        CesiumGeospatial::Ellipsoid::WGS84.cartographicToCartesian(launch);
    const CesiumGeospatial::LocalHorizontalCoordinateSystem frame =
        makeRealityKitLocalFrame(origin);
    const glm::dmat4 ecefFromLocal = frame.getLocalToEcefTransformation();
    const glm::dvec3 localOrigin = frame.ecefPositionToLocal(origin);
    const glm::dvec3 localEast = frame.ecefPositionToLocal(
        origin + glm::normalize(glm::dvec3(ecefFromLocal[0])) * 100.0);
    const glm::dvec3 localUp = frame.ecefPositionToLocal(
        origin + glm::normalize(glm::dvec3(ecefFromLocal[1])) * 100.0);
    const glm::dvec3 localSouth = frame.ecefPositionToLocal(
        origin + glm::normalize(glm::dvec3(ecefFromLocal[2])) * 100.0);
    const bool isCorrect = glm::length(localOrigin) < 1e-6 &&
        glm::length(localEast - glm::dvec3(100.0, 0.0, 0.0)) < 1e-6 &&
        glm::length(localUp - glm::dvec3(0.0, 100.0, 0.0)) < 1e-6 &&
        glm::length(localSouth - glm::dvec3(0.0, 0.0, 100.0)) < 1e-6;
    return isCorrect
        ? @"RealityKit local horizontal frame: OK"
        : @"RealityKit local horizontal frame: FAILED";
}

+ (simd_double3)ecefPositionWithLongitudeDegrees:(double)longitudeDegrees
                                  latitudeDegrees:(double)latitudeDegrees
                           ellipsoidHeightMeters:(double)ellipsoidHeightMeters {
    const CesiumGeospatial::Cartographic cartographic =
        CesiumGeospatial::Cartographic::fromDegrees(
            longitudeDegrees,
            latitudeDegrees,
            ellipsoidHeightMeters);
    return simdVectorFromGlm(
        CesiumGeospatial::Ellipsoid::WGS84.cartographicToCartesian(cartographic));
}

+ (simd_double3)cartographicDegreesFromEcefPosition:(simd_double3)ecefPosition {
    const std::optional<CesiumGeospatial::Cartographic> cartographic =
        CesiumGeospatial::Ellipsoid::WGS84.cartesianToCartographic(
            glmVectorFromSimd(ecefPosition));
    if (!cartographic) {
        const double nan = std::numeric_limits<double>::quiet_NaN();
        return simd_make_double3(nan, nan, nan);
    }
    return simd_make_double3(
        cartographic->longitude * 180.0 / M_PI,
        cartographic->latitude * 180.0 / M_PI,
        cartographic->height);
}

+ (simd_double4x4)ecefFromLocalHorizontalAtEcefPosition:(simd_double3)ecefPosition {
    return simdMatrixFromGlm(
        makeRealityKitLocalFrame(glmVectorFromSimd(ecefPosition))
            .getLocalToEcefTransformation());
}

+ (double)egm96HeightAboveWGS84EllipsoidAtLongitudeDegrees:(double)longitudeDegrees
                                           latitudeDegrees:(double)latitudeDegrees {
    const CesiumGeospatial::Cartographic location =
        CesiumGeospatial::Cartographic::fromDegrees(longitudeDegrees, latitudeDegrees);
    const double height = loadedEGM96Grid().sampleHeight(location);
    NSCAssert(std::isfinite(height), @"EGM96 returned a nonfinite height");
    return height;
}

+ (void)startTilesWithAPIKey:(NSString *)apiKey
           maximumScreenSpaceError:(double)maximumScreenSpaceError
      maximumSimultaneousTileLoads:(uint32_t)maximumSimultaneousTileLoads
                maximumCachedBytes:(int64_t)maximumCachedBytes
              lodTransitionsEnabled:(BOOL)lodTransitionsEnabled
          lodTransitionLengthSeconds:(float)lodTransitionLengthSeconds
                     onTileVisible:(void (^)(NSString *tileIdentifier, NSArray<CesiumPrimitivePayload *> *primitives))onTileVisible
                      onTileHidden:(void (^)(NSString *tileIdentifier))onTileHidden
                        onTileFreed:(void (^)(NSString *tileIdentifier))onTileFreed
              onAttributionChanged:(void (^)(NSString *attribution))onAttributionChanged {
    if (apiKey.length == 0) {
        NSLog(@"Google Maps API key is empty. Add it to ignored Secrets.xcconfig.");
        return;
    }
    tileReady = [onTileVisible copy];
    tileHidden = [onTileHidden copy];
    tileFreed = [onTileFreed copy];
    attributionChanged = [onAttributionChanged copy];
    lastAttribution.clear();
    lodTransitionsAreEnabled = lodTransitionsEnabled;
    pauseLodTransitionsForPendingInstall = false;
    realityKitInstalledTiles.clear();
    Cesium3DTilesContent::registerAllTileContentTypes();
    Cesium3DTilesSelection::TilesetExternals externals{
        nullptr,
        nullptr,
        CesiumAsync::AsyncSystem(std::make_shared<DispatchTaskProcessor>())
    };
    externals.pAssetAccessor = std::make_shared<GoogleAssetAccessor>(std::make_shared<AppleAssetAccessor>(), apiKey);
    externals.pPrepareRendererResources = std::make_shared<RendererPreparation>();
    externals.pLogger = makeSanitizedCesiumLogger();
    creditSystem = std::make_shared<CesiumUtility::CreditSystem>();
    externals.pCreditSystem = creditSystem;
    Cesium3DTilesSelection::TilesetOptions options;
    // Preserve the settled preload policy and keep all quality/load controls in
    // EarthflightTuning rather than layering another selector over Cesium.
    options.maximumSimultaneousTileLoads = maximumSimultaneousTileLoads;
    options.preloadAncestors = false;
    options.preloadSiblings = false;
    // These are Cesium's native projected-error and bounded-cache controls. They
    // remain owner-editable in EarthflightTuning.swift; no second LOD or cache is
    // layered over Cesium's selection.
    options.maximumScreenSpaceError = std::max(maximumScreenSpaceError, 0.1);
    options.maximumCachedBytes = static_cast<int64_t>(std::max<int64_t>(maximumCachedBytes, 0));
    options.enableLodTransitionPeriod = lodTransitionsEnabled;
    options.lodTransitionLength = std::max(lodTransitionLengthSeconds, 0.001f);
    options.kickDescendantsWhileFadingIn = true;
    tileset = std::make_unique<Cesium3DTilesSelection::Tileset>(
        externals, "https://tile.googleapis.com/v1/3dtiles/root.json", options);
}

+ (void)updateTilesWithEcefCameraPositionX:(double)positionX
                                   positionY:(double)positionY
                                   positionZ:(double)positionZ
                                  directionX:(double)directionX
                                  directionY:(double)directionY
                                  directionZ:(double)directionZ
                                         upX:(double)upX
                                         upY:(double)upY
                                         upZ:(double)upZ
                                   deltaTime:(double)deltaTime {
    if (!tileset) return;
    tileset->getAsyncSystem().dispatchMainThreadTasks();
    glm::dvec3 ecefDirection(directionX, directionY, directionZ);
    glm::dvec3 ecefUp(upX, upY, upZ);
    if (glm::length(ecefDirection) < 1e-9 ||
        glm::length(ecefUp) < 1e-9 ||
        glm::length(glm::cross(ecefDirection, ecefUp)) < 1e-9) return;
    ecefDirection = glm::normalize(ecefDirection);
    ecefUp -= glm::dot(ecefUp, ecefDirection) * ecefDirection;
    ecefUp = glm::normalize(ecefUp);
    const Cesium3DTilesSelection::ViewState view = {
        {positionX, positionY, positionZ},
        ecefDirection,
        ecefUp,
        {1024.0, 1024.0},
        1.57,
        1.22
    };
    const float frameDelta = static_cast<float>(std::clamp(deltaTime, 0.0, 0.1));
    // Cesium's transition clock normally starts as soon as content is selected,
    // before Earthflight's asynchronous RealityKit mesh and texture creation has
    // necessarily attached that content. Freeze transition progress until every
    // currently selected replacement has confirmed installation, keeping its old
    // LOD opaque rather than exposing the sky between the two renderer lifecycles.
    const float transitionDelta =
        lodTransitionsAreEnabled && pauseLodTransitionsForPendingInstall
            ? 0.0f
            : frameDelta;
    const Cesium3DTilesSelection::ViewUpdateResult& result =
        tileset->updateViewGroup(
            tileset->getDefaultViewGroup(),
            {view},
            transitionDelta);
    for (const Cesium3DTilesSelection::Tile::ConstPointer& tile : result.tilesFadingOut) {
        const Cesium3DTilesSelection::TileRenderContent *content = tile->getContent().getRenderContent();
        auto *resources = content ? static_cast<TileRenderResources *>(content->getRenderResources()) : nullptr;
        if (!resources || !resources->identifier) continue;
        if (!lodTransitionsAreEnabled) {
            if (tileHidden) tileHidden(resources->identifier);
            continue;
        }
        // Keep the outgoing RealityKit container fully opaque for the complete
        // overlap window. Partial hierarchy opacity exposes background geometry
        // because the two LOD meshes have competing depth surfaces.
        const float progress = std::clamp(content->getLodTransitionFadePercentage(), 0.0f, 1.0f);
        if (progress >= 1.0f && tileHidden) {
            tileHidden(resources->identifier);
        }
    }
    bool hasPendingRealityKitInstall = false;
    for (const Cesium3DTilesSelection::Tile::ConstPointer& tile : result.tilesToRenderThisFrame) {
        const Cesium3DTilesSelection::TileRenderContent *content = tile->getContent().getRenderContent();
        auto *resources = content ? static_cast<TileRenderResources *>(content->getRenderResources()) : nullptr;
        if (resources && resources->identifier && resources->primitives.count > 0 && tileReady) {
            if (!realityKitInstalledTiles.contains(resources->identifier.UTF8String)) {
                hasPendingRealityKitInstall = true;
            }
            tileReady(resources->identifier, resources->primitives);
        }
    }
    pauseLodTransitionsForPendingInstall = hasPendingRealityKitInstall;
    if (creditSystem && attributionChanged) {
        const CesiumUtility::CreditsSnapshot& snapshot = creditSystem->getSnapshot();
        std::string currentAttribution;
        for (const CesiumUtility::Credit& credit : snapshot.currentCredits) {
            if (!currentAttribution.empty()) currentAttribution += " · ";
            currentAttribution += creditSystem->getHtml(credit);
        }
        if (currentAttribution != lastAttribution) {
            lastAttribution = currentAttribution;
            attributionChanged([NSString stringWithUTF8String:lastAttribution.c_str()]);
        }
    }
    tileset->loadTiles();
}

+ (void)tileDidFinishInstalling:(NSString *)tileIdentifier {
    realityKitInstalledTiles.insert(tileIdentifier.UTF8String);
}

@end
