# Building Earthflight

This file records a known-good physical-device Cesium Native build. It intentionally contains facts, not prospective instructions.

## Current status

The visionOS arm64 Cesium Native build links and runs on the original M2 Apple Vision Pro. It launches over central London into Google Photorealistic 3D Tiles with correct geometry, textures, sampler behaviour, tile replacement, and visible-tile attribution aggregation, and keeps them while the craft flies and jumps elsewhere.

Since 10 September 2026 the Swift code builds in **Swift 6 language mode**; see "The 10 September 2026 Swift 6 language-mode move" below for what that changed and what it caught.

## Known-good build record

| Item | Value |
|---|---|
| Cesium Native commit | `80a22ff4337c5b7057cff53d0055045c15c6d350` (upstream v0.64.0) |
| vcpkg commit | `56bb2411609227288b70117ead2c47585ba07713` |
| Xcode version and build | Xcode 27.0 (`27A5252f`), a beta build |
| visionOS SDK version and build | 27.0 (`XROS27.0.sdk`, `24M5357a`) |
| Apple Clang version | 21.0.0 (`clang-2100.3.33.1`) |
| visionOS deployment target | 27.0 |
| Swift language mode | 6.0, `SWIFT_STRICT_CONCURRENCY = complete` (since 10 September 2026) |
| Host macOS | 27.0 (`26A428`), release candidate |
| Device visionOS | 27.0 (`24M362`), release candidate, on the paired Apple Vision Pro |
| `DEVELOPER_DIR` resolved to | `/Applications/Xcode-beta.app/Contents/Developer` (the only full Xcode installation on this machine; see below for how this is chosen) |
| Local patches | `patches/cesium-native-visionos.patch`; `patches/vcpkg-openssl-visionos.patch` |
| Physical-device smoke test | Successful on original M2 Apple Vision Pro; fixed London tiles refined correctly and rendered without black or misassigned textures. |

## The 10 September 2026 release-candidate OS update

macOS and visionOS both moved to release-candidate builds — the host to 27.0 (`26A428`), the paired Apple Vision Pro to 27.0 (`24M362`). Xcode did not change: it is still the same beta `Xcode-beta.app`, Xcode 27.0 (`27A5252f`), carrying `XROS27.0.sdk` build `24M5357a` and `clang-2100.3.33.1`.

Nothing the build manifest records as toolchain identity therefore changed, and the native archives built on 5 September 2026 remain the ones in use (`BUILT_AT=2026-09-05T14:36:08Z`). AGENTS.md "Toolchain transitions" asks for a native rebuild after an Xcode or SDK change; a device OS change alone is not one. The headset now runs a *newer* visionOS build than the SDK the app is compiled against, which is ordinary: the deployment target is 27.0 and visionOS keeps binary compatibility forward within a release.

The macOS update did leave `xcode-select -p` pointing at `/Library/Developer/CommandLineTools`, so plain `xcodebuild` is no longer on `PATH`. `scripts/build-cesium-visionos.sh` run without `DEVELOPER_DIR` now falls through to its `/Applications` scan, finds exactly one full Xcode and proceeds after printing "No Xcode selected via xcode-select". The build command recorded in the next section sets `DEVELOPER_DIR` explicitly and does not depend on that; `sudo xcode-select -s /Applications/Xcode-beta.app` restores the selection if a bare `xcodebuild` is wanted.

Verified on 10 September 2026, with no rebuild of the native dependencies:

* the "Verify Cesium Native toolchain" build phase reports the manifest matching the active toolchain, so the app compiles and links against the 5 September archives unchanged;
* `xcodebuild test` on the paired physical Apple Vision Pro, now on visionOS `24M362`, runs and passes all 28 cases in `earthflightTests`. The 21 recorded below are the count on 5 September; the sky, star-field and head-up display work has added cases since.

## The 10 September 2026 Swift 6 language-mode move

`SWIFT_VERSION` went from `5.0` to `6.0` and `SWIFT_STRICT_CONCURRENCY = complete` was added, on all four configurations — the app and `earthflightTests`, Debug and Release. `SWIFT_APPROACHABLE_CONCURRENCY = YES` and the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` were already set and did not change.

**No native rebuild was involved.** Xcode, the SDK, the compiler and both pinned source revisions are exactly as recorded above, so the "Verify Cesium Native toolchain" phase matched and the app compiled and linked against the 5 September archives unchanged. A language-mode change is not a toolchain transition.

Verified on 10 September 2026:

* `xcodebuild build` for `generic/platform=visionOS` succeeds in **both Debug and Release** with no Swift warnings. The only remaining compiler warnings are pre-existing: documentation warnings from Cesium's own headers, and `CesiumBridge.mm:319` `-Wunused-getter-return-value`. Both were present before the move; confirmed by rebuilding a stash of the pre-change tree.
* `xcodebuild test` on the paired physical Apple Vision Pro runs and passes all 28 cases in `earthflightTests`.
* The owner then confirmed on the headset that flight, tile streaming, the head-up display and its `-` toggle, the sky gradient, the star field, Jump To and on-device speech recognition all work. That is the first run to have exercised every visible subsystem in one sitting, so it also retires the "not seen on the headset" status lines the sky, star-field and head-up-display sections of AGENTS.md had carried.

### The one thing it broke, and why that was the point

The first headset run trapped the moment `+` was pressed, in libdispatch's `_dispatch_assert_queue_fail`:

```text
BUG IN CLIENT OF LIBDISPATCH: Assertion failed:
Block was expected to execute on queue [com.apple.main-thread (...)]
```

The cause was `SFSpeechRecognizer.requestAuthorization`'s completion handler. `SFSpeechRecognizer.h` states that "the system does not guarantee the execution of this block on your app's main dispatch queue", and it does arrive on another one. Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` the handler closure is inferred `@MainActor`, and **Swift 6 emits a hard runtime check inside the bridged Objective-C block thunk where Swift 5 emitted none**. The handler itself was untouched by the migration; only enforcement changed. It is now a `nonisolated` helper, `JumpTo.speechAuthorizationStatus`.

Confirmed by measurement rather than inference: compiling the same source at `-swift-version 5` and `-swift-version 6` yields one versus three `swift_task_isCurrentExecutor` call sites, and demangling the enclosing symbols pins the extra pair to that handler. AGENTS.md, "Swift 6: where every callback actually runs", holds the resulting rule, the per-callback contracts, and the recipe for sweeping the whole binary for the same fault.

### `build-for-testing` in Release fails, and always has

```text
error: Unable to resolve Swift module dependency to a compatible module: 'earthflight'
```

`@testable import earthflight` cannot resolve because `ENABLE_TESTABILITY` is off in Release. Confirmed pre-existing by building a stash of the tree before the Swift 6 change. Tests run in Debug; do not chase this.

## Native build commands

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/build-cesium-visionos.sh
```

The script initialises the pinned submodules, applies both idempotent local patches, configures with Ninja, builds, and installs under the ignored `build/cesium-visionos/install` directory. It also produces `build/cesium-visionos/vcpkg_installed/arm64-visionos/lib/libEarthflightAbseil.a`; see below.

## The `libEarthflightAbseil.a` archive

`OTHER_LDFLAGS` links a single `-lEarthflightAbseil`, but no tracked source ever names that archive: s2geometry (a transitive dependency of `CesiumGeospatial`) declares about twenty direct `absl::*` link targets, and vcpkg's abseil port installs their closure as ninety-one separate `libabsl_*.a` files with a dense internal dependency graph. Apple's linker resolves each static archive in one left-to-right pass, so listing ninety-one archives by hand in Xcode's link order is fragile: whichever archive happens to need a symbol from one listed later fails unless the order already accounts for it.

`scripts/build-cesium-visionos.sh` now concatenates every installed `libabsl_*.a` into one `libEarthflightAbseil.a` with `xcrun libtool -static`, immediately after `cmake --install`. A single merged archive removes the ordering problem entirely, because the linker's ordinary multi-pass symbol resolution within one archive already handles it; this is Abseil's own documented answer to exactly this problem. The merge step regenerates the archive on every run, so it stays in step with whatever vcpkg's pinned abseil port last built; it is not hand-maintained and nothing should copy or hand-edit it.

Before 5 September 2026 this archive existed only as a hand-built file inside the ignored `build/` tree, created by an earlier session and never reproduced by the tracked script. A clean checkout could not build until someone repeated that manual step. Do not delete a merged archive under `build/` expecting the script to rebuild an equivalent one from a stale `vcpkg_installed` layout; rerun the whole script.

Verified on 5 September 2026 in an isolated scratch checkout — a clean `git clone` of this repository plus fresh, unpatched clones of `ThirdParty/cesium-native` and `ThirdParty/vcpkg` at the two pinned commits above, entirely separate from this repository's own `build/` directory and `Secrets.xcconfig`:

* the merged archive holds exactly the 156 real object members and 2,307 defined global symbols present across all ninety-one source archives (`__.SYMDEF` table-of-contents entries excluded from both counts; duplicate object basenames across different abseil components, such as two unrelated files both named `usage.cc.o`, are expected and harmless);
* `xcodebuild build` for `generic/platform=visionOS` succeeds in both Debug and Release, linking only libraries under the scratch checkout's own `build/` tree;
* `xcodebuild test` on the paired physical Apple Vision Pro runs and passes all 21 cases in `earthflightTests`.

Building for `platform=visionOS Simulator` fails at the link step against these libraries, because the native build script only ever configures the device `XROS.sdk` and the `arm64-visionos` vcpkg triplet. That is pre-existing and unrelated to the archive fix; the physical device remains the only buildable and testable destination.

## Toolchain identity: resolution, the build manifest, and the Xcode-side check

`scripts/build-cesium-visionos.sh` honours an explicit `DEVELOPER_DIR` as-is (it must be a full Xcode, not `/Library/Developer/CommandLineTools`). Otherwise it uses whichever full Xcode `xcode-select -p` currently selects. Only when nothing is selected does it scan `/Applications`, and only proceeds automatically if exactly one full Xcode installation is found there; with zero or several it stops and asks for an explicit `DEVELOPER_DIR` rather than silently preferring one installation (e.g. `Xcode-beta.app`) over another.

After every run it writes `build/cesium-visionos/build-manifest.txt` — flat `KEY=VALUE` facts about the toolchain and pinned sources that produced that build directory: `DEVELOPER_DIR`, `XCODE_VERSION`/`XCODE_BUILD`, `CLANG_VERSION`, `XROS_SDK_VERSION`/`XROS_SDK_BUILD`, `DEPLOYMENT_TARGET`, `TARGET_TRIPLET`, `TARGET_ARCH`, `BUILD_TYPE`, `CESIUM_NATIVE_COMMIT`, `VCPKG_COMMIT`, `CESIUM_PATCH_SHA256`, `VCPKG_PATCH_SHA256`, `BUILT_AT`, and `CXX_STANDARD`/`ABI_DEFINES`. The last two — the effective C++ standard and the compile definitions that affect the layout of types Cesium's public headers expose (glm's, mainly) — are read back from CMake's own generated `compile_commands.json` rather than assumed; per-library `*_BUILDING` export macros are excluded as private to each archive.

Before configuring, the script compares its freshly computed identity (everything above except `BUILT_AT`, `CXX_STANDARD` and `ABI_DEFINES`, which are only knowable after building) against any existing manifest. Any difference — including Xcode having been replaced in place at the same `DEVELOPER_DIR` path — discards only `build/cesium-visionos` (the stale CMake configuration and `vcpkg_installed` binaries) and reconfigures from clean. It never touches `build/vcpkg-downloads`, `build/vcpkg-binary-cache`, `build/vcpkg-cache`, or `Secrets.xcconfig`.

The `earthflight` Xcode target's first build phase, "Verify Cesium Native toolchain" (`scripts/check-native-toolchain.sh`), runs before Sources/Frameworks on every build. It compares the active Xcode build, Clang version, visionOS SDK build, deployment target and architecture, plus the pinned Cesium/vcpkg commits and patch hashes, against `build-manifest.txt`, and fails the build with the exact rebuild command if anything is stale — so opening a different Xcode cannot silently compile or link against a native build produced by another toolchain. This phase needed `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the target: Xcode's script sandbox otherwise denies read access under `SRCROOT` (the manifest, the patch files, and the two `ThirdParty` git checkouts) even to a phase's own declared script file.

Verified on 5 September 2026, on this machine (only `Xcode-beta.app` installed, so an actual beta-to-release swap was not exercised):

* an unchanged rerun of `scripts/build-cesium-visionos.sh` reports no mismatch and reproduces the same manifest, modulo `BUILT_AT`;
* a manifest field edited to a stale value makes the script print the mismatch, discard only `build/cesium-visionos`, and rebuild — `build/vcpkg-downloads`, `build/vcpkg-binary-cache`, `build/vcpkg-cache` and `Secrets.xcconfig` were unaffected;
* `xcodebuild build` for `generic/platform=visionOS` succeeds in both Debug and Release with a correct manifest, and fails clearly, with the precise rebuild command, when a manifest field is deliberately corrupted;
* `xcodebuild test` on the paired physical Apple Vision Pro still runs and passes all 21 cases in `earthflightTests` afterwards.

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
