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

The script initializes the pinned submodules, applies both idempotent local patches, configures with Ninja, builds, and installs under the ignored `build/cesium-visionos/install` directory. It also produces `build/cesium-visionos/vcpkg_installed/arm64-visionos/lib/libEarthflightAbseil.a`; see below.

## The `libEarthflightAbseil.a` archive

`OTHER_LDFLAGS` links a single `-lEarthflightAbseil`, but no tracked source ever names that archive: s2geometry (a transitive dependency of `CesiumGeospatial`) declares about twenty direct `absl::*` link targets, and vcpkg's abseil port installs their closure as ninety-one separate `libabsl_*.a` files with a dense internal dependency graph. Apple's linker resolves each static archive in one left-to-right pass, so listing ninety-one archives by hand in Xcode's link order is fragile: whichever archive happens to need a symbol from one listed later fails unless the order already accounts for it.

`scripts/build-cesium-visionos.sh` now concatenates every installed `libabsl_*.a` into one `libEarthflightAbseil.a` with `xcrun libtool -static`, immediately after `cmake --install`. A single merged archive removes the ordering problem entirely, because the linker's ordinary multi-pass symbol resolution within one archive already handles it; this is Abseil's own documented answer to exactly this problem. The merge step regenerates the archive on every run, so it stays in step with whatever vcpkg's pinned abseil port last built; it is not hand-maintained and nothing should copy or hand-edit it.

Before 5 September 2026 this archive existed only as a hand-built file inside the ignored `build/` tree, created by an earlier session and never reproduced by the tracked script. A clean checkout could not build until someone repeated that manual step. Do not delete a merged archive under `build/` expecting the script to rebuild an equivalent one from a stale `vcpkg_installed` layout; rerun the whole script.

Verified on 5 September 2026 in an isolated scratch checkout — a clean `git clone` of this repository plus fresh, unpatched clones of `ThirdParty/cesium-native` and `ThirdParty/vcpkg` at the two pinned commits above, entirely separate from this repository's own `build/` directory and `Secrets.xcconfig`:

* the merged archive holds exactly the 156 real object members and 2,307 defined global symbols present across all ninety-one source archives (`__.SYMDEF` table-of-contents entries excluded from both counts; duplicate object basenames across different abseil components, such as two unrelated files both named `usage.cc.o`, are expected and harmless);
* `xcodebuild build` for `generic/platform=visionOS` succeeds in both Debug and Release, linking only libraries under the scratch checkout's own `build/` tree;
* `xcodebuild test` on the paired physical Apple Vision Pro (`RuxVision`) runs and passes all 21 cases in `earthflightTests`.

Building for `platform=visionOS Simulator` fails at the link step against these libraries, because the native build script only ever configures the device `XROS.sdk` and the `arm64-visionos` vcpkg triplet. That is pre-existing and unrelated to the archive fix; the physical device remains the only buildable and testable destination.

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
