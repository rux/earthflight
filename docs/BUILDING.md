# Building Earthflight

Earthflight builds only for a physical Apple Vision Pro. It links Cesium Native as static libraries built from source for visionOS arm64.

## Known-good toolchain

The native libraries must be built by the same Xcode that builds the app. This combination is known to work:

| Item | Value |
|---|---|
| Xcode | 27.0 (`27A266a`), at `/Applications/Xcode.app` |
| visionOS SDK | 27.0 (`XROS27.0.sdk`, `24M361`) |
| Apple Clang | 21.0.0 (`clang-2100.3.34.2`) |
| visionOS deployment target | 27.0 |
| Swift language mode | 6.0, `SWIFT_STRICT_CONCURRENCY = complete` |
| Cesium Native | `80a22ff4337c5b7057cff53d0055045c15c6d350` (upstream v0.64.0), submodule `ThirdParty/cesium-native` |
| vcpkg | `56bb2411609227288b70117ead2c47585ba07713`, submodule `ThirdParty/vcpkg` |
| Local patches | `patches/cesium-native-visionos.patch`, `patches/vcpkg-openssl-visionos.patch` |
| Host tools | CMake 4.4 and Ninja 1.13, from Homebrew |
| Device | Original M2 Apple Vision Pro on visionOS 27.0 (`24M362`) |

## Steps

From the repository root:

1. Install CMake and Ninja (`brew install cmake ninja`).
2. Copy `Secrets.example.xcconfig` to `Secrets.xcconfig` and set `GOOGLE_MAPS_API_KEY` to a Google Map Tiles API key. The file is ignored by Git.
3. Build the native dependencies. This takes several minutes the first time:

   ```sh
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   scripts/build-cesium-visionos.sh
   ```

4. Build the app, and run the tests on the paired headset:

   ```sh
   xcodebuild build -project earthflight.xcodeproj -scheme earthflight \
     -configuration Debug -destination 'generic/platform=visionOS'

   xcodebuild test -project earthflight.xcodeproj -scheme earthflight \
     -configuration Debug -destination 'platform=visionOS,id=<device UDID>'
   ```

Set `DEVELOPER_DIR` explicitly unless `xcode-select -p` already points at a full Xcode. When it points at `/Library/Developer/CommandLineTools`, `xcodebuild` is not available.

## What the native build script does

`scripts/build-cesium-visionos.sh`:

* initialises the two pinned submodules and applies both patches (reapplying is safe);
* configures Cesium Native with Ninja against the `xros` SDK and the `arm64-visionos` vcpkg triplet, builds it, and installs under `build/cesium-visionos/install`;
* merges all of vcpkg's `libabsl_*.a` archives into `build/cesium-visionos/vcpkg_installed/arm64-visionos/lib/libEarthflightAbseil.a`;
* writes `build/cesium-visionos/build-manifest.txt`, which records the toolchain and source pins that produced the build.

The script is the single source of truth for CMake options; do not duplicate them elsewhere.

**Choosing an Xcode.** An explicit `DEVELOPER_DIR` is used as-is and must be a full Xcode. Otherwise the script uses whichever Xcode `xcode-select` selects. If nothing is selected, it scans `/Applications` and continues only if it finds exactly one Xcode.

**The patches.** Cesium Native and vcpkg treat iOS as the only Apple platform without JIT. The patches extend that to visionOS: asmjit is left out, blend2d's `jit` feature is disabled, and OpenSSL is built for `darwin64-arm64` with `no-asm`.

**Why Abseil is merged.** s2geometry, which `CesiumGeospatial` depends on, pulls in 91 separate Abseil archives with a dense web of dependencies between them. Apple's linker makes one left-to-right pass over static archives, so no hand-written link order is reliable. One merged archive avoids the problem, and the app links it with `-lEarthflightAbseil`. The script regenerates it on every run; never copy or edit it by hand.

**Rebuilding when the toolchain changes.** Before configuring, the script compares the current toolchain and source pins with the manifest. If anything differs, it deletes `build/cesium-visionos` and rebuilds from clean. The download and binary caches in `build/vcpkg-*` and `Secrets.xcconfig` are left alone.

## The Xcode-side check

The `earthflight` target's first build phase, "Verify Cesium Native toolchain" (`scripts/check-native-toolchain.sh`), compares the active Xcode location and build, Clang version, SDK build, deployment target, architecture, pinned commits and patch hashes with `build-manifest.txt`. If anything differs, it fails the build and prints the rebuild command. Run that command; do not work around the check. Linking libraries built by another toolchain is not supported.

The phase needs `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the target, because the sandbox blocks reads of the manifest, the patches and the submodule checkouts.

After a new Xcode or SDK: rebuild the native dependencies, rebuild the app, run the tests and a headset smoke test, then update the table above.

## Known limitations

* The visionOS Simulator cannot link: the native libraries are built only for devices.
* `build-for-testing` fails in Release, because `ENABLE_TESTABILITY` is off there and `@testable import earthflight` cannot resolve. Run tests in Debug.
* Expected compiler warnings: documentation warnings from Cesium's headers, and `-Wunused-getter-return-value` at `CesiumBridge.mm:319`. Anything else is new.
