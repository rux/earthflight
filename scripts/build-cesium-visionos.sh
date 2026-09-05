#!/bin/zsh

set -euo pipefail

earthflight_root="$(cd "$(dirname "$0")/.." && pwd)"
cesium_source="$earthflight_root/ThirdParty/cesium-native"
vcpkg_source="$earthflight_root/ThirdParty/vcpkg"
cesium_build="$earthflight_root/build/cesium-visionos"
vcpkg_cache="$earthflight_root/build/vcpkg-cache"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    else
        print -u2 "Set DEVELOPER_DIR to the Xcode 27 developer directory."
        exit 1
    fi
fi

git -C "$earthflight_root" submodule update --init --recursive ThirdParty/cesium-native ThirdParty/vcpkg

apply_patch_if_needed() {
    local repository="$1"
    local patch_file="$2"

    if git -C "$repository" apply --reverse --check "$patch_file" 2>/dev/null; then
        return
    fi

    git -C "$repository" apply --check "$patch_file"
    git -C "$repository" apply "$patch_file"
}

apply_patch_if_needed "$cesium_source" "$earthflight_root/patches/cesium-native-visionos.patch"
apply_patch_if_needed "$vcpkg_source" "$earthflight_root/patches/vcpkg-openssl-visionos.patch"

if [[ ! -x "$vcpkg_source/vcpkg" ]]; then
    "$vcpkg_source/bootstrap-vcpkg.sh" -disableMetrics
fi

cmake_command="$(command -v cmake)"
ninja_command="$(command -v ninja)"
xros_sdk="$(xcrun --sdk xros --show-sdk-path)"

mkdir -p \
    "$vcpkg_cache/registries" \
    "$earthflight_root/build/vcpkg-downloads" \
    "$earthflight_root/build/vcpkg-binary-cache"

export XDG_CACHE_HOME="$vcpkg_cache"
export VCPKG_ROOT="$vcpkg_source"
export VCPKG_DOWNLOADS="$earthflight_root/build/vcpkg-downloads"
export VCPKG_DEFAULT_BINARY_CACHE="$earthflight_root/build/vcpkg-binary-cache"

"$cmake_command" \
    -S "$cesium_source" \
    -B "$cesium_build" \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$ninja_command" \
    -DCMAKE_TOOLCHAIN_FILE="$vcpkg_source/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET=arm64-visionos \
    -DVCPKG_HOST_TRIPLET=arm64-osx \
    -DVCPKG_OVERLAY_PORTS="$vcpkg_source/ports/openssl" \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_SYSROOT="$xros_sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCESIUM_USE_EZVCPKG=OFF \
    -DCESIUM_TESTS_ENABLED=OFF \
    -DCESIUM_ENABLE_CLANG_TIDY=OFF \
    -DCMAKE_INSTALL_PREFIX="$cesium_build/install"

"$cmake_command" --build "$cesium_build" --parallel
"$cmake_command" --install "$cesium_build"

# s2geometry (a Cesium dependency, via CesiumGeospatial) links about ninety
# separate libabsl_*.a archives with a dense internal dependency graph. Apple's
# linker resolves a static archive in one left-to-right pass, so listing that
# many archives by hand in Xcode's link order is fragile: whichever archive
# happens to need a symbol from a later one fails unless the order already
# accounts for it. Concatenating every installed abseil archive into one
# archive removes the ordering problem entirely, because the linker's normal
# multi-pass symbol resolution within a single archive already handles this.
# Xcode's project only ever links "-lEarthflightAbseil"; this is the one place
# that archive is produced, deterministically, from the pinned vcpkg abseil
# port, rather than depending on a hand-built copy in the ignored build tree.
vcpkg_install_lib="$cesium_build/vcpkg_installed/arm64-visionos/lib"
absl_archives=("$vcpkg_install_lib"/libabsl_*.a(N))
if (( ${#absl_archives[@]} == 0 )); then
    print -u2 "No libabsl_*.a archives found under $vcpkg_install_lib; abseil was not installed by vcpkg."
    exit 1
fi
xcrun libtool -static -o "$vcpkg_install_lib/libEarthflightAbseil.a" "${absl_archives[@]}"
