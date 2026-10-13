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
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <dispatch/dispatch.h>
#include <glm/geometric.hpp>
#include <glm/trigonometric.hpp>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <spdlog/sinks/callback_sink.h>
#include <type_traits>
#include <unordered_map>
#include <variant>

using namespace Cesium3DTilesSelection;

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

/// Logs and crashes in every build configuration. `NSAssert` is compiled out of
/// Release, and nothing checked with this is worth limping past.
void require(bool condition, NSString *message) {
    if (!condition) {
        NSLog(@"%@", message);
        abort();
    }
}

// MARK: - Coordinates

CesiumGeospatial::LocalHorizontalCoordinateSystem makeRealityKitLocalFrame(
    const glm::dvec3& originEcef) {
    // Right-handed and metre-scale, to suit RealityKit: X east, Y geodetic up,
    // Z south.
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

std::optional<CesiumGeospatial::EarthGravitationalModel1996Grid> egm96Grid;

const CesiumGeospatial::EarthGravitationalModel1996Grid& loadedEGM96Grid() {
    if (!egm96Grid) {
        NSURL *url = [NSBundle.mainBundle URLForResource:@"WW15MGH" withExtension:@"DAC"];
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        require(data != nil, @"WW15MGH.DAC must be bundled with Earthflight");
        egm96Grid = CesiumGeospatial::EarthGravitationalModel1996Grid::fromBuffer(
            std::span<const std::byte>(static_cast<const std::byte *>(data.bytes), data.length));
        require(egm96Grid.has_value(), @"Bundled WW15MGH.DAC is malformed");
    }
    return *egm96Grid;
}

// MARK: - glTF to RealityKit payloads

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
        output[static_cast<size_t>(i)] = normalized
            ? glm::dvec2(normalizedComponent(value[0]), normalizedComponent(value[1]))
            : glm::dvec2(value[0], value[1]);
    }
    return true;
}

/// Texture coordinates in whatever component type and normalisation the
/// accessor declares. The accessor view honours its byte offsets and stride.
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
    // glTF puts (0, 0) at the image's upper left. RealityKit's generated meshes
    // use the USD convention, with V running the other way. This is the only
    // flip: decoded image rows are left in their original order.
    return {gltfTextureCoordinate.x, 1.0 - gltfTextureCoordinate.y};
}

/// The primitive's indices widened to UInt32, or nil if they are missing or
/// malformed or point past the last vertex. Filled in one pass into a buffer
/// sized up front: appending index by index cost seven times as much.
NSData *_Nullable widenedIndices(
    const CesiumGltf::Model& gltf,
    int32_t accessorIndex,
    int64_t vertexCount) {
    const CesiumGltf::Accessor *accessor = CesiumGltf::Model::getSafe(&gltf.accessors, accessorIndex);
    if (!accessor) return nil;
    auto widen = [&](auto view) -> NSData *_Nullable {
        if (view.status() != CesiumGltf::AccessorViewStatus::Valid) return nil;
        NSMutableData *data = [NSMutableData dataWithLength:
            static_cast<NSUInteger>(view.size()) * sizeof(uint32_t)];
        uint32_t *output = static_cast<uint32_t *>(data.mutableBytes);
        for (int64_t i = 0; i < view.size(); ++i) {
            const uint32_t index = static_cast<uint32_t>(view[i]);
            if (index >= vertexCount) return nil;
            output[i] = index;
        }
        return data;
    };
    switch (accessor->componentType) {
        case CesiumGltf::Accessor::ComponentType::UNSIGNED_BYTE:
            return widen(CesiumGltf::AccessorView<uint8_t>(gltf, accessorIndex));
        case CesiumGltf::Accessor::ComponentType::UNSIGNED_SHORT:
            return widen(CesiumGltf::AccessorView<uint16_t>(gltf, accessorIndex));
        case CesiumGltf::Accessor::ComponentType::UNSIGNED_INT:
            return widen(CesiumGltf::AccessorView<uint32_t>(gltf, accessorIndex));
        default:
            return nil;
    }
}

/// The image's full-resolution RGBA8 texels, copied for RealityKit, or nil if
/// it is not RGBA8 or its sizes disagree. Cesium may keep generated mip levels
/// back to back after the first; RealityKit makes its own, so only the first
/// is wanted.
NSData *_Nullable baseLevelRGBA8(const CesiumGltf::Image& image) {
    const CesiumImage::ImageAsset *asset = image.pAsset.get();
    if (!asset || asset->channels != 4 || asset->bytesPerChannel != 1) return nil;
    size_t byteOffset = 0;
    size_t byteLength = asset->pixelData.size();
    if (!asset->mipPositions.empty()) {
        byteOffset = asset->mipPositions.front().byteOffset;
        byteLength = asset->mipPositions.front().byteSize;
    }
    const size_t expectedByteLength =
        static_cast<size_t>(asset->width) * static_cast<size_t>(asset->height) * 4;
    if (byteLength != expectedByteLength ||
        byteOffset + byteLength > asset->pixelData.size()) return nil;
    return [NSData dataWithBytes:asset->pixelData.data() + byteOffset length:byteLength];
}

/// One triangle primitive as a RealityKit payload, or nil if RealityKit cannot
/// draw it: no positions, indices or base-colour texture, or data that
/// contradicts its own declarations.
CesiumPrimitivePayload *_Nullable makePayload(
    const CesiumGltf::Model& gltf,
    const CesiumGltf::MeshPrimitive& primitive,
    const glm::dmat4& ecefFromNodeLocal) {
    const CesiumGltf::Material *material = CesiumGltf::Model::getSafe(&gltf.materials, primitive.material);
    if (!material || !material->pbrMetallicRoughness ||
        !material->pbrMetallicRoughness->baseColorTexture) return nil;
    const CesiumGltf::TextureInfo& textureInfo = *material->pbrMetallicRoughness->baseColorTexture;
    const CesiumGltf::Texture *texture = CesiumGltf::Model::getSafe(&gltf.textures, textureInfo.index);
    const CesiumGltf::Image *image = texture ? CesiumGltf::Model::getSafe(&gltf.images, texture->source) : nullptr;
    NSData *pixels = image ? baseLevelRGBA8(*image) : nil;
    if (!pixels) return nil;

    // KHR_texture_transform may name a different texture-coordinate set from
    // the one on the texture info.
    const CesiumGltf::ExtensionKhrTextureTransform *transformExtension =
        textureInfo.getExtension<CesiumGltf::ExtensionKhrTextureTransform>();
    const CesiumGltf::KhrTextureTransform textureTransform = transformExtension
        ? CesiumGltf::KhrTextureTransform(*transformExtension)
        : CesiumGltf::KhrTextureTransform();
    const int64_t textureCoordinateSet = transformExtension && transformExtension->texCoord
        ? *transformExtension->texCoord
        : textureInfo.texCoord;

    const auto positionAttribute = primitive.attributes.find("POSITION");
    const auto uvAttribute = primitive.attributes.find("TEXCOORD_" + std::to_string(textureCoordinateSet));
    if (positionAttribute == primitive.attributes.end() ||
        uvAttribute == primitive.attributes.end()) return nil;
    CesiumGltf::AccessorView<glm::vec3> positions(gltf, positionAttribute->second);
    std::vector<glm::dvec2> uvs;
    if (positions.status() != CesiumGltf::AccessorViewStatus::Valid ||
        positions.size() == 0 ||
        !decodeUVs(gltf, uvAttribute->second, uvs) ||
        static_cast<size_t>(positions.size()) != uvs.size()) return nil;

    NSData *indices = widenedIndices(gltf, primitive.indices, positions.size());
    if (!indices) return nil;

    // Every vertex goes to ECEF in Double first. Their mean anchors the
    // primitive's own local frame, so the one cast to Float happens in metres
    // close to the geometry, where it loses nothing visible.
    std::vector<glm::dvec3> ecefPositions(static_cast<size_t>(positions.size()));
    glm::dvec3 anchorEcef(0.0);
    for (int64_t i = 0; i < positions.size(); ++i) {
        const glm::dvec3 ecef(ecefFromNodeLocal * glm::dvec4(positions[i], 1.0));
        ecefPositions[static_cast<size_t>(i)] = ecef;
        anchorEcef += ecef;
    }
    anchorEcef /= static_cast<double>(positions.size());
    // A coarse primitive can span enough of the globe for its mean to fall
    // towards the Earth's centre. A real vertex is a better anchor then.
    if (glm::length(anchorEcef) < CesiumGeospatial::Ellipsoid::WGS84.getMinimumRadius() * 0.5) {
        anchorEcef = ecefPositions.front();
    }
    const CesiumGeospatial::LocalHorizontalCoordinateSystem primitiveFrame =
        makeRealityKitLocalFrame(anchorEcef);

    NSMutableData *positionData = [NSMutableData dataWithLength:uvs.size() * sizeof(float) * 3];
    NSMutableData *uvData = [NSMutableData dataWithLength:uvs.size() * sizeof(float) * 2];
    float *outPositions = static_cast<float *>(positionData.mutableBytes);
    float *outUVs = static_cast<float *>(uvData.mutableBytes);
    for (size_t i = 0; i < uvs.size(); ++i) {
        const glm::dvec3 local = primitiveFrame.ecefPositionToLocal(ecefPositions[i]);
        outPositions[i * 3] = static_cast<float>(local.x);
        outPositions[i * 3 + 1] = static_cast<float>(local.y);
        outPositions[i * 3 + 2] = static_cast<float>(local.z);
        // KHR_texture_transform is defined in glTF's texture space, so it is
        // applied before converting to RealityKit's.
        const glm::dvec2 uv = realityKitTextureCoordinate(transformExtension
            ? textureTransform.applyTransform(uvs[i].x, uvs[i].y)
            : uvs[i]);
        outUVs[i * 2] = static_cast<float>(uv.x);
        outUVs[i * 2 + 1] = static_cast<float>(uv.y);
    }

    CesiumPrimitivePayload *payload = [CesiumPrimitivePayload new];
    payload.positions = positionData;
    payload.textureCoordinates = uvData;
    payload.indices = indices;
    payload.rgbaImage = pixels;
    payload.imageWidth = image->pAsset->width;
    payload.imageHeight = image->pAsset->height;
    payload.ecefFromPrimitiveLocal = simdMatrixFromGlm(primitiveFrame.getLocalToEcefTransformation());
    const CesiumGltf::Sampler *sampler = CesiumGltf::Model::getSafe(&gltf.samplers, texture->sampler);
    payload.samplerWrapS = sampler ? sampler->wrapS : CesiumGltf::Sampler::WrapS::REPEAT;
    payload.samplerWrapT = sampler ? sampler->wrapT : CesiumGltf::Sampler::WrapT::REPEAT;
    payload.samplerMinFilter = sampler && sampler->minFilter
        ? *sampler->minFilter
        : CesiumGltf::Sampler::MinFilter::LINEAR_MIPMAP_LINEAR;
    payload.samplerMagFilter = sampler && sampler->magFilter
        ? *sampler->magFilter
        : CesiumGltf::Sampler::MagFilter::LINEAR;
    // Culling is per material, and Google tiles may mix single- and
    // double-sided surfaces.
    payload.doubleSided = material->doubleSided;
    return payload;
}

/// Every triangle primitive in the model as a RealityKit payload, or nil if any
/// of them cannot be drawn, or there are none. A tile with a primitive missing
/// would cover its ground only in part, so that counts as failure.
NSArray<CesiumPrimitivePayload *> *_Nullable makePayloads(
    CesiumGltf::Model& model,
    const glm::dmat4& tileTransform) {
    // Positions are relative to the model's CESIUM_RTC centre, which Cesium
    // keeps in the model rather than folding into the tile transform.
    const glm::dmat4 ecefFromModel = CesiumGltfContent::GltfUtilities::applyGltfUpAxisTransform(
        model,
        CesiumGltfContent::GltfUtilities::applyRtcCenter(model, tileTransform));
    NSMutableArray<CesiumPrimitivePayload *> *payloads = [NSMutableArray array];
    bool everyPrimitiveIsDrawable = true;
    model.forEachPrimitiveInScene(-1, [&](
        CesiumGltf::Model& gltf,
        CesiumGltf::Node&,
        CesiumGltf::Mesh&,
        CesiumGltf::MeshPrimitive& primitive,
        const glm::dmat4& nodeTransform) {
        if (primitive.mode != CesiumGltf::MeshPrimitive::Mode::TRIANGLES) return;
        CesiumPrimitivePayload *payload = makePayload(gltf, primitive, ecefFromModel * nodeTransform);
        if (payload) {
            [payloads addObject:payload];
        } else {
            everyPrimitiveIsDrawable = false;
        }
    });
    return everyPrimitiveIsDrawable && payloads.count > 0 ? payloads : nil;
}

/// Drops Cesium's decoded texels once the payloads hold their own copy.
/// Otherwise every cached tile's texture is held twice: once here and once by
/// RealityKit. `sizeBytes` keeps Cesium's cache accounting as it would have
/// been with the texels kept, so `maximumCachedBytes` still buys the same
/// number of tiles. An image owned by a shared-asset depot may belong to other
/// tiles too, so it is left alone.
void releaseDecodedImages(CesiumGltf::Model& model) {
    for (CesiumGltf::Image& image : model.images) {
        CesiumImage::ImageAsset *asset = image.pAsset.get();
        if (!asset || asset->getDepot() != nullptr) continue;
        if (asset->sizeBytes < 0) {
            asset->sizeBytes = static_cast<int64_t>(asset->pixelData.size());
        }
        asset->pixelData.clear();
        asset->pixelData.shrink_to_fit();
    }
}

// MARK: - Networking

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
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@(url.c_str())]];
        request.HTTPMethod = @(verb.c_str());
        CesiumAsync::HttpHeaders requestHeaders;
        for (const THeader& header : headers) {
            [request setValue:@(header.second.c_str()) forHTTPHeaderField:@(header.first.c_str())];
            requestHeaders.emplace(header.first, header.second);
        }
        if (!payload.empty()) request.HTTPBody = [NSData dataWithBytes:payload.data() length:payload.size()];
        auto assetRequest = std::make_shared<AppleAssetRequest>(verb, url, std::move(requestHeaders));
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (!http) {
                NSLog(@"Google tile request failed: domain=%@ code=%ld", error.domain ?: @"unknown", (long)error.code);
            } else if (http.statusCode >= 400) {
                NSLog(@"Google tile request failed: HTTP %ld (%lu bytes)", (long)http.statusCode, (unsigned long)data.length);
            }
            // With no HTTP response at all, the request carries no response,
            // which every Cesium loader treats as a failed load.
            if (http) {
                assetRequest->setResponse(std::make_shared<AppleAssetResponse>(http, data ?: [NSData data]));
            }
            promise.resolve(assetRequest);
        }];
        [task resume];
        return future;
    }

    void tick() noexcept override {}
};

std::string decorateGoogleURL(const std::string& url, NSString *apiKey) {
    @autoreleasepool {
        NSURLComponents *components = [NSURLComponents componentsWithString:@(url.c_str())];
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

/// Adds the API key to every Google tile request. Child URLs already carry
/// Google's session parameter, which must be preserved.
class GoogleAssetAccessor final : public CesiumAsync::IAssetAccessor {
public:
    GoogleAssetAccessor(std::shared_ptr<CesiumAsync::IAssetAccessor> accessor, NSString *apiKey)
        : accessor_(std::move(accessor)), apiKey_([apiKey copy]) {}

    CesiumAsync::Future<std::shared_ptr<CesiumAsync::IAssetRequest>> get(
        const CesiumAsync::AsyncSystem& asyncSystem, const std::string& url,
        const std::vector<THeader>& headers) override {
        return accessor_->get(asyncSystem, decorateGoogleURL(url, apiKey_), headers);
    }

    CesiumAsync::Future<std::shared_ptr<CesiumAsync::IAssetRequest>> request(
        const CesiumAsync::AsyncSystem& asyncSystem, const std::string& verb,
        const std::string& url, const std::vector<THeader>& headers,
        const std::span<const std::byte>& payload) override {
        return accessor_->request(asyncSystem, verb, decorateGoogleURL(url, apiKey_), headers, payload);
    }

    void tick() noexcept override { accessor_->tick(); }

private:
    std::shared_ptr<CesiumAsync::IAssetAccessor> accessor_;
    NSString *apiKey_;
};

std::shared_ptr<spdlog::logger> makeSanitizedCesiumLogger() {
    // Built directly rather than through spdlog::callback_logger_mt, which
    // registers the name in spdlog's global registry and throws when a reopened
    // session registers it again.
    auto sink = std::make_shared<spdlog::sinks::callback_sink_mt>(
        [](const spdlog::details::log_msg& message) {
        // Google URLs carry the API key. Keep the status or error, never the
        // key or the request path.
        std::string text(message.payload.data(), message.payload.size());
        size_t key = text.find("key=");
        while (key != std::string::npos) {
            size_t end = text.find_first_of("&`' \n", key);
            text.replace(key + 4, end == std::string::npos ? std::string::npos : end - key - 4, "REDACTED");
            key = text.find("key=", key + 12);
        }
        size_t url = text.find("https://tile.googleapis.com/");
        while (url != std::string::npos) {
            size_t end = text.find_first_of("`' \n", url);
            text.replace(url, end == std::string::npos ? std::string::npos : end - url, "Google tile URL omitted");
            url = text.find("https://tile.googleapis.com/", url + 23);
        }
        NSLog(@"Cesium: %@", @(text.c_str()));
    });
    auto logger = std::make_shared<spdlog::logger>("EarthflightCesium", sink);
    logger->set_level(spdlog::level::warn);
    return logger;
}

// MARK: - Tasks and the session

class DispatchTaskProcessor final : public CesiumAsync::ITaskProcessor {
public:
    void startTask(std::function<void()> task) override {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ task(); });
    }
};

/// One task system for the whole process, pumped every frame. A destroyed
/// tileset finishes its in-flight loads asynchronously through this system's
/// main-thread queue, so the system must outlive every tileset that used it.
CesiumAsync::AsyncSystem& sharedAsyncSystem() {
    static CesiumAsync::AsyncSystem asyncSystem(std::make_shared<DispatchTaskProcessor>());
    return asyncSystem;
}

/// Everything belonging to the running session. Main thread only.
struct Session {
    uint64_t number;
    std::unique_ptr<Tileset> tileset;
    std::shared_ptr<CesiumUtility::CreditSystem> creditSystem;
    std::string attribution;
    glm::dvec2 viewportSize;
    double horizontalFieldOfViewRadians;
    double verticalFieldOfViewRadians;
    void (^prepareTile)(uint64_t, NSArray<CesiumPrimitivePayload *> *);
    void (^tileSelected)(uint64_t);
    void (^selectionComplete)(void);
    void (^tileFreed)(uint64_t);
    void (^attributionChanged)(NSString *);
};

std::optional<Session> session;
uint64_t lastSessionNumber = 0;

/// Cesium measures screen-space error in viewport pixels across the vertical
/// field of view, so the viewport's height sets how big Cesium thinks a pixel
/// is. This height makes one of its pixels one headset pixel at the centre of
/// view; the width only keeps the aspect ratio honest.
glm::dvec2 viewportSizeInHeadsetPixels(const CesiumTileSelectionSettings& settings) {
    const double halfHorizontal = glm::radians(settings.horizontalFieldOfViewDegrees) / 2;
    const double halfVertical = glm::radians(settings.verticalFieldOfViewDegrees) / 2;
    const double pixelsPerRadian = settings.headsetPixelsPerDegree * 180 / M_PI;
    const double height = 2 * std::tan(halfVertical) * pixelsPerRadian;
    return {height * std::tan(halfHorizontal) / std::tan(halfVertical), height};
}

// MARK: - Renderer preparation

std::atomic<uint64_t> nextTileIdentifier{1};

// Cesium carries one opaque pointer of render resources per tile. Earthflight's
// only per-tile resource is its identifier, so the pointer *is* the identifier:
// nothing is allocated and nothing needs freeing. Identifiers start at 1, so a
// null pointer still means none. They are never the `Tile` address, which
// Cesium recycles.
void *renderResources(uint64_t identifier) {
    return reinterpret_cast<void *>(static_cast<uintptr_t>(identifier));
}

uint64_t tileIdentifier(const void *resources) {
    return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(resources));
}

/// A tile Cesium is waiting on while RealityKit builds it.
struct PendingPreparation {
    TileLoadResult result;
    CesiumAsync::Promise<TileLoadResultAndRenderResources> promise;
};

std::mutex pendingPreparationsMutex;
std::unordered_map<uint64_t, PendingPreparation> pendingPreparations;

void resolvePreparation(PendingPreparation&& pending, uint64_t identifier, bool succeeded) {
    if (!succeeded) {
        pending.result.state = TileLoadResultState::Failed;
    }
    pending.promise.resolve({
        std::move(pending.result),
        succeeded ? renderResources(identifier) : nullptr});
}

void finishPreparation(uint64_t identifier, bool succeeded) {
    std::optional<PendingPreparation> pending;
    {
        std::lock_guard<std::mutex> lock(pendingPreparationsMutex);
        auto node = pendingPreparations.extract(identifier);
        if (node.empty()) return;
        pending.emplace(std::move(node.mapped()));
    }
    resolvePreparation(std::move(*pending), identifier, succeeded);
}

/// Builds RealityKit's copy of each tile before Cesium may select it. Cesium
/// cannot mark a tile `Done` until the future returned here resolves, and that
/// waits for Swift's answer, so a selected tile is always ready to draw.
class RendererPreparation final : public IPrepareRendererResources {
public:
    explicit RendererPreparation(uint64_t sessionNumber) : sessionNumber_(sessionNumber) {}

    CesiumAsync::Future<TileLoadResultAndRenderResources> prepareInLoadThread(
        const CesiumAsync::AsyncSystem& asyncSystem, TileLoadResult&& result,
        const glm::dmat4& tileTransform, const std::any&) override {
        CesiumGltf::Model *model = std::get_if<CesiumGltf::Model>(&result.contentKind);
        if (result.state != TileLoadResultState::Success || !model) {
            // Empty, external or failed content: nothing for RealityKit to build.
            return asyncSystem.createResolvedFuture(
                TileLoadResultAndRenderResources{std::move(result), nullptr});
        }

        const uint64_t identifier = nextTileIdentifier.fetch_add(1, std::memory_order_relaxed);
        NSArray<CesiumPrimitivePayload *> *payloads = makePayloads(*model, tileTransform);
        if (!payloads) {
            NSLog(@"Cesium tile %llu has content RealityKit cannot draw; it will be left out.", identifier);
            result.state = TileLoadResultState::Failed;
            return asyncSystem.createResolvedFuture(
                TileLoadResultAndRenderResources{std::move(result), nullptr});
        }
        releaseDecodedImages(*model);

        auto promise = asyncSystem.createPromise<TileLoadResultAndRenderResources>();
        auto future = promise.getFuture();
        {
            std::lock_guard<std::mutex> lock(pendingPreparationsMutex);
            pendingPreparations.emplace(identifier, PendingPreparation{std::move(result), promise});
        }
        const uint64_t sessionNumber = sessionNumber_;
        dispatch_async(dispatch_get_main_queue(), ^{
            // A stopped tileset finishes its last loads after its session has
            // gone. That work must not reach a later session's renderer.
            if (session && session->number == sessionNumber) {
                session->prepareTile(identifier, payloads);
            } else {
                finishPreparation(identifier, false);
            }
        });
        return future;
    }

    void *prepareInMainThread(Tile&, void *loadThreadResources) override {
        return loadThreadResources;
    }

    void free(Tile&, void *loadThreadResources, void *mainThreadResources) noexcept override {
        const uint64_t identifier = tileIdentifier(mainThreadResources ?: loadThreadResources);
        if (identifier == 0) return;
        const uint64_t sessionNumber = sessionNumber_;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (session && session->number == sessionNumber) {
                session->tileFreed(identifier);
            }
        });
    }

    void *prepareRasterInLoadThread(CesiumImage::ImageAsset&, const std::any&) override { return nullptr; }
    void *prepareRasterInMainThread(CesiumRasterOverlays::RasterOverlayTile&, void *) override { return nullptr; }
    void freeRaster(const CesiumRasterOverlays::RasterOverlayTile&, void *, void *) noexcept override {}
    void attachRasterInMainThread(const Tile&, int32_t, const CesiumRasterOverlays::RasterOverlayTile&, void *, const glm::dvec2&, const glm::dvec2&) override {}
    void detachRasterInMainThread(const Tile&, int32_t, const CesiumRasterOverlays::RasterOverlayTile&, void *) noexcept override {}

private:
    /// Read on Cesium's worker threads, so it never changes.
    const uint64_t sessionNumber_;
};

} // namespace

@implementation CesiumBridge

+ (simd_double3)ecefPositionWithLongitudeDegrees:(double)longitudeDegrees
                                  latitudeDegrees:(double)latitudeDegrees
                           ellipsoidHeightMeters:(double)ellipsoidHeightMeters {
    const CesiumGeospatial::Cartographic cartographic =
        CesiumGeospatial::Cartographic::fromDegrees(longitudeDegrees, latitudeDegrees, ellipsoidHeightMeters);
    return simdVectorFromGlm(CesiumGeospatial::Ellipsoid::WGS84.cartographicToCartesian(cartographic));
}

+ (simd_double3)cartographicDegreesFromEcefPosition:(simd_double3)ecefPosition {
    const std::optional<CesiumGeospatial::Cartographic> cartographic =
        CesiumGeospatial::Ellipsoid::WGS84.cartesianToCartographic(glmVectorFromSimd(ecefPosition));
    if (!cartographic) {
        const double nan = std::numeric_limits<double>::quiet_NaN();
        return simd_make_double3(nan, nan, nan);
    }
    return simd_make_double3(
        glm::degrees(cartographic->longitude),
        glm::degrees(cartographic->latitude),
        cartographic->height);
}

+ (simd_double4x4)ecefFromLocalHorizontalAtEcefPosition:(simd_double3)ecefPosition {
    return simdMatrixFromGlm(
        makeRealityKitLocalFrame(glmVectorFromSimd(ecefPosition)).getLocalToEcefTransformation());
}

+ (double)egm96HeightAboveWGS84EllipsoidAtLongitudeDegrees:(double)longitudeDegrees
                                           latitudeDegrees:(double)latitudeDegrees {
    const double height = loadedEGM96Grid().sampleHeight(
        CesiumGeospatial::Cartographic::fromDegrees(longitudeDegrees, latitudeDegrees));
    require(std::isfinite(height), @"EGM96 returned a nonfinite height");
    return height;
}

+ (void)startTilesWithAPIKey:(NSString *)apiKey
                    settings:(CesiumTileSelectionSettings)settings
               onPrepareTile:(void (^)(uint64_t, NSArray<CesiumPrimitivePayload *> *))onPrepareTile
              onTileSelected:(void (^)(uint64_t))onTileSelected
         onSelectionComplete:(void (^)(void))onSelectionComplete
                 onTileFreed:(void (^)(uint64_t))onTileFreed
        onAttributionChanged:(void (^)(NSString *))onAttributionChanged {
    require(!session, @"startTiles called while a session is already running");
    if (apiKey.length == 0) {
        NSLog(@"Google Maps API key is empty. Add it to the ignored Secrets.xcconfig.");
        return;
    }
    Cesium3DTilesContent::registerAllTileContentTypes();

    const uint64_t number = ++lastSessionNumber;
    auto creditSystem = std::make_shared<CesiumUtility::CreditSystem>();
    const TilesetExternals externals{
        .pAssetAccessor = std::make_shared<GoogleAssetAccessor>(std::make_shared<AppleAssetAccessor>(), apiKey),
        .pPrepareRendererResources = std::make_shared<RendererPreparation>(number),
        .asyncSystem = sharedAsyncSystem(),
        .pCreditSystem = creditSystem,
        .pLogger = makeSanitizedCesiumLogger(),
    };

    TilesetOptions options;
    options.maximumScreenSpaceError = settings.maximumScreenSpaceErrorHeadsetPixels;
    options.forbidHoles = settings.forbidHoles;
    options.loadingDescendantLimit = settings.loadingDescendantLimit;
    options.maximumSimultaneousTileLoads = settings.maximumSimultaneousTileLoads;
    options.maximumCachedBytes = settings.maximumCachedBytes;
    // Only what is selected is loaded: no ancestors or siblings ahead of need.
    options.preloadAncestors = false;
    options.preloadSiblings = false;
    // `enableLodTransitionPeriod` stays at its default, off. Turning it on
    // switches frustum and fog culling off outright, which floods the selection
    // with tiles from around the globe.

    session = Session{
        .number = number,
        .tileset = std::make_unique<Tileset>(externals, "https://tile.googleapis.com/v1/3dtiles/root.json", options),
        .creditSystem = creditSystem,
        .viewportSize = viewportSizeInHeadsetPixels(settings),
        .horizontalFieldOfViewRadians = glm::radians(settings.horizontalFieldOfViewDegrees),
        .verticalFieldOfViewRadians = glm::radians(settings.verticalFieldOfViewDegrees),
        .prepareTile = onPrepareTile,
        .tileSelected = onTileSelected,
        .selectionComplete = onSelectionComplete,
        .tileFreed = onTileFreed,
        .attributionChanged = onAttributionChanged,
    };
}

+ (void)updateTilesWithCameraPosition:(simd_double3)ecefPosition
                            direction:(simd_double3)ecefDirection
                                   up:(simd_double3)ecefUp
                            deltaTime:(double)deltaTime {
    sharedAsyncSystem().dispatchMainThreadTasks();
    if (!session) return;

    glm::dvec3 direction = glmVectorFromSimd(ecefDirection);
    glm::dvec3 up = glmVectorFromSimd(ecefUp);
    if (glm::length(glm::cross(direction, up)) < 1e-9) return;
    direction = glm::normalize(direction);
    up = glm::normalize(up - glm::dot(up, direction) * direction);

    // One view, at the head, wider than the display so a quick head turn finds
    // ground already selected.
    const ViewState view(
        glmVectorFromSimd(ecefPosition),
        direction,
        up,
        session->viewportSize,
        session->horizontalFieldOfViewRadians,
        session->verticalFieldOfViewRadians);
    const ViewUpdateResult& result = session->tileset->updateViewGroup(
        session->tileset->getDefaultViewGroup(),
        {view},
        static_cast<float>(std::clamp(deltaTime, 0.0, 0.1)));

    bool selectionIsComplete = true;
    for (const Tile::ConstPointer& tile : result.tilesToRenderThisFrame) {
        switch (tile->getState()) {
            case TileLoadState::Done:
                break;
            case TileLoadState::Failed:
                // Cesium selects a failed tile as if it were empty and does not
                // retry it while it stays selected. Waiting for it would hold
                // back every other change for as long as it is in view; leaving
                // it out costs a hole in that one tile.
                continue;
            default:
                // Still loading.
                selectionIsComplete = false;
                continue;
        }
        if (tile->isEmptyContent()) continue;
        const TileRenderContent *content = tile->getContent().getRenderContent();
        const uint64_t identifier = content ? tileIdentifier(content->getRenderResources()) : 0;
        if (identifier == 0) {
            // External tileset content, which only leads to the tiles that draw.
            selectionIsComplete = false;
            continue;
        }
        session->tileSelected(identifier);
    }
    if (selectionIsComplete) {
        session->selectionComplete();
    }

    // Cesium sorts the current credits by how many visible tiles use each,
    // which is the order Google asks for.
    const CesiumUtility::CreditsSnapshot& snapshot = session->creditSystem->getSnapshot();
    std::string attribution;
    for (const CesiumUtility::Credit& credit : snapshot.currentCredits) {
        if (!attribution.empty()) attribution += " · ";
        attribution += session->creditSystem->getHtml(credit);
    }
    if (attribution != session->attribution) {
        session->attribution = attribution;
        session->attributionChanged(@(attribution.c_str()));
    }

    session->tileset->loadTiles();
}

+ (void)tileDidFinishPreparing:(uint64_t)tileIdentifier succeeded:(BOOL)succeeded {
    finishPreparation(tileIdentifier, succeeded);
}

+ (void)stopTiles {
    if (!session) return;

    // Settle every promise this bridge made. A `tileDidFinishPreparing` that
    // arrives later for one of these finds nothing and does nothing.
    std::unordered_map<uint64_t, PendingPreparation> abandoned;
    {
        std::lock_guard<std::mutex> lock(pendingPreparationsMutex);
        abandoned.swap(pendingPreparations);
    }
    for (auto& [identifier, pending] : abandoned) {
        resolvePreparation(std::move(pending), identifier, false);
    }

    // End the session before destroying its tileset, so nothing the
    // destruction schedules can reach Swift. Loads still in flight finish
    // later through the shared task system and are discarded.
    std::unique_ptr<Tileset> tileset = std::move(session->tileset);
    session.reset();
    tileset.reset();
}

+ (NSString *)decoratedGoogleURLForTesting:(NSString *)url apiKey:(NSString *)apiKey {
    return @(decorateGoogleURL(url.UTF8String, apiKey).c_str());
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

@end
