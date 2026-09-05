#!/bin/zsh
#
# Xcode "Verify Cesium Native toolchain" build phase for the earthflight
# target. Runs before Sources/Frameworks so a stale native build — produced
# by a different Xcode, SDK, or pinned Cesium/vcpkg source — fails the app
# build up front instead of silently compiling against mismatched headers or
# linking ABI-incompatible static archives. See AGENTS.md "Toolchain
# transitions".
#
# Xcode sets DEVELOPER_DIR and the other build settings read below to match
# whichever Xcode is actually running this build, so no separate resolution
# is needed here the way scripts/build-cesium-visionos.sh needs one when run
# standalone from a shell.

set -euo pipefail

project_dir="${SRCROOT}"
source "$project_dir/scripts/native-toolchain-manifest.sh"

manifest_file="$project_dir/build/cesium-visionos/build-manifest.txt"

fail() {
    print -u2 "error: $1"
    print -u2 ""
    print -u2 "Rebuild the native Cesium dependencies for this toolchain, then build again:"
    print -u2 "  DEVELOPER_DIR=\"$DEVELOPER_DIR\" \"$project_dir/scripts/build-cesium-visionos.sh\""
    exit 1
}

if [[ ! -f "$manifest_file" ]]; then
    fail "no native build manifest at $manifest_file — the Cesium Native bootstrap has never been run for this checkout."
fi

clang_version="$(xcrun clang --version | head -1)"
cesium_native_commit="$(git -C "$project_dir/ThirdParty/cesium-native" rev-parse HEAD)"
vcpkg_commit="$(git -C "$project_dir/ThirdParty/vcpkg" rev-parse HEAD)"
cesium_patch_sha256="$(shasum -a 256 "$project_dir/patches/cesium-native-visionos.patch" | awk '{print $1}')"
vcpkg_patch_sha256="$(shasum -a 256 "$project_dir/patches/vcpkg-openssl-visionos.patch" | awk '{print $1}')"

typeset -A current
current=(
    DEVELOPER_DIR        "$DEVELOPER_DIR"
    XCODE_BUILD          "$XCODE_PRODUCT_BUILD_VERSION"
    CLANG_VERSION        "$clang_version"
    XROS_SDK_VERSION     "$SDK_VERSION"
    XROS_SDK_BUILD       "$SDK_PRODUCT_BUILD_VERSION"
    DEPLOYMENT_TARGET    "$XROS_DEPLOYMENT_TARGET"
    TARGET_ARCH          "$ARCHS"
    CESIUM_NATIVE_COMMIT "$cesium_native_commit"
    VCPKG_COMMIT         "$vcpkg_commit"
    CESIUM_PATCH_SHA256  "$cesium_patch_sha256"
    VCPKG_PATCH_SHA256   "$vcpkg_patch_sha256"
)

for key value in "${(kv)current[@]}"; do
    recorded="$(manifest_get "$manifest_file" "$key")"
    if [[ "$recorded" != "$value" ]]; then
        fail "native build manifest is stale: $key was '$recorded' when Cesium Native was last built, but this build reports '$value'."
    fi
done

print "Native build manifest matches the active toolchain (Xcode $XCODE_PRODUCT_BUILD_VERSION, SDK $SDK_PRODUCT_BUILD_VERSION)."
