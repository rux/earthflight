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
