# Building Earthflight

This file records a known-good physical-device Cesium Native build. It intentionally contains facts, not prospective instructions.

## Current status

The visionOS arm64 Cesium Native build links and runs on the original M2 Apple Vision Pro. It starts at a fixed central-London Google Photorealistic 3D Tiles view with correct geometry, textures, sampler behavior, tile replacement, and visible-tile attribution aggregation.

## Known-good build record

| Item | Value |
|---|---|
| Cesium Native commit | `80a22ff4337c5b7057cff53d0055045c15c6d350` (upstream v0.64.0) |
| vcpkg commit | `56bb2411609227288b70117ead2c47585ba07713` |
| Xcode version and build | Xcode 27.0 (`27A5252f`) |
| visionOS SDK version | 27.0 (`XROS27.0.sdk`) |
| Apple Clang version | 21.0.0 (`clang-2100.3.33.1`) |
| visionOS deployment target | 27.0 |
| `DEVELOPER_DIR` convention | `/Applications/Xcode-beta.app/Contents/Developer` |
| Local patches | `patches/cesium-native-visionos.patch`; `patches/vcpkg-openssl-visionos.patch` |
| Physical-device smoke test | Successful on original M2 Apple Vision Pro; fixed London tiles refined correctly and rendered without black or misassigned textures. |

## Native build commands

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/build-cesium-visionos.sh
```

The script initializes the pinned submodules, applies both idempotent local patches, configures with Ninja, builds, and installs under the ignored `build/cesium-visionos/install` directory.

## Required CMake options

The build script configures:

```text
-DCMAKE_TOOLCHAIN_FILE=ThirdParty/vcpkg/scripts/buildsystems/vcpkg.cmake
-DVCPKG_TARGET_TRIPLET=arm64-visionos
-DVCPKG_HOST_TRIPLET=arm64-osx
-DVCPKG_OVERLAY_PORTS=ThirdParty/vcpkg/ports/openssl
-DCMAKE_SYSTEM_NAME=visionOS
-DCMAKE_OSX_SYSROOT=<xcrun --sdk xros --show-sdk-path>
-DCMAKE_OSX_ARCHITECTURES=arm64
-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0
-DCMAKE_BUILD_TYPE=Release
-DCESIUM_USE_EZVCPKG=OFF
-DCESIUM_TESTS_ENABLED=OFF
-DCESIUM_ENABLE_CLANG_TIDY=OFF
-DCMAKE_INSTALL_PREFIX=build/cesium-visionos/install
```
