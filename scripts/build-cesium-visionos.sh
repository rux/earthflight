#!/bin/zsh

set -euo pipefail

earthflight_root="$(cd "$(dirname "$0")/.." && pwd)"
cesium_source="$earthflight_root/ThirdParty/cesium-native"
vcpkg_source="$earthflight_root/ThirdParty/vcpkg"
cesium_build="$earthflight_root/build/cesium-visionos"
vcpkg_cache="$earthflight_root/build/vcpkg-cache"
manifest_file="$cesium_build/build-manifest.txt"

source "$earthflight_root/scripts/native-toolchain-manifest.sh"

# Resolve the Xcode installation this build will run under. An explicit
# DEVELOPER_DIR is always honoured as-is (it must still be a full Xcode, not
# the bare command-line tools). Otherwise resolve whichever full Xcode is
# currently selected via `xcode-select`, and only fall back to scanning
# /Applications when nothing is selected — never silently prefer one
# particular Xcode installation (e.g. Xcode-beta.app) over another.
is_full_xcode() {
    [[ -x "$1/usr/bin/xcodebuild" && "$1" != "/Library/Developer/CommandLineTools" ]]
}

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    if ! is_full_xcode "$DEVELOPER_DIR"; then
        print -u2 "DEVELOPER_DIR ($DEVELOPER_DIR) is not a full Xcode installation."
        exit 1
    fi
else
    selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if is_full_xcode "$selected_developer_dir"; then
        export DEVELOPER_DIR="$selected_developer_dir"
    else
        full_xcodes=(/Applications/*.app/Contents/Developer(N))
        candidates=()
        for candidate in "${full_xcodes[@]}"; do
            is_full_xcode "$candidate" && candidates+=("$candidate")
        done

        if (( ${#candidates[@]} == 0 )); then
            print -u2 "No full Xcode installation found (xcode-select points at '$selected_developer_dir'). Install Xcode or set DEVELOPER_DIR explicitly."
            exit 1
        elif (( ${#candidates[@]} > 1 )); then
            print -u2 "Multiple Xcode installations found; set DEVELOPER_DIR explicitly to pick one:"
            printf '  %s\n' "${candidates[@]}" >&2
            exit 1
        fi

        print -u2 "No Xcode selected via xcode-select; using the only full Xcode installation found: ${candidates[1]}"
        export DEVELOPER_DIR="${candidates[1]}"
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

cesium_patch="$earthflight_root/patches/cesium-native-visionos.patch"
vcpkg_patch="$earthflight_root/patches/vcpkg-openssl-visionos.patch"

apply_patch_if_needed "$cesium_source" "$cesium_patch"
apply_patch_if_needed "$vcpkg_source" "$vcpkg_patch"

if [[ ! -x "$vcpkg_source/vcpkg" ]]; then
    "$vcpkg_source/bootstrap-vcpkg.sh" -disableMetrics
fi

cmake_command="$(command -v cmake)"
ninja_command="$(command -v ninja)"
xros_sdk="$(xcrun --sdk xros --show-sdk-path)"

deployment_target="27.0"
target_triplet="arm64-visionos"
target_arch="arm64"
build_type="Release"

# The identity of the toolchain and pinned sources that are about to produce
# build/cesium-visionos. Compared below against whatever produced the
# existing build directory, if any.
xcodebuild_version_output="$(xcodebuild -version)"
xcode_version="$(print -r -- "$xcodebuild_version_output" | sed -n '1s/^Xcode //p')"
xcode_build="$(print -r -- "$xcodebuild_version_output" | sed -n '2s/^Build version //p')"
clang_version="$(xcrun clang --version | head -1)"
xros_sdk_version="$(xcrun --sdk xros --show-sdk-version)"
xros_sdk_build="$(xcrun --sdk xros --show-sdk-build-version)"
cesium_native_commit="$(git -C "$cesium_source" rev-parse HEAD)"
vcpkg_commit="$(git -C "$vcpkg_source" rev-parse HEAD)"
cesium_patch_sha256="$(shasum -a 256 "$cesium_patch" | awk '{print $1}')"
vcpkg_patch_sha256="$(shasum -a 256 "$vcpkg_patch" | awk '{print $1}')"

# Fields that, if any differs from the manifest of the existing build
# directory, mean that directory's CMake configuration and vcpkg_installed
# binaries can no longer be trusted (different compiler, SDK, or pinned
# source) and must not be reused incrementally — including the case where
# Xcode was replaced in place at the same DEVELOPER_DIR path, which shows up
# here as a changed XCODE_BUILD/CLANG_VERSION/XROS_SDK_BUILD even though the
# path string is unchanged.
typeset -A identity
identity=(
    DEVELOPER_DIR        "$DEVELOPER_DIR"
    XCODE_BUILD          "$xcode_build"
    CLANG_VERSION        "$clang_version"
    XROS_SDK_VERSION      "$xros_sdk_version"
    XROS_SDK_BUILD       "$xros_sdk_build"
    DEPLOYMENT_TARGET    "$deployment_target"
    TARGET_TRIPLET       "$target_triplet"
    TARGET_ARCH          "$target_arch"
    BUILD_TYPE           "$build_type"
    CESIUM_NATIVE_COMMIT "$cesium_native_commit"
    VCPKG_COMMIT         "$vcpkg_commit"
    CESIUM_PATCH_SHA256  "$cesium_patch_sha256"
    VCPKG_PATCH_SHA256   "$vcpkg_patch_sha256"
)

if [[ -f "$manifest_file" ]]; then
    stale=0
    for key value in "${(kv)identity[@]}"; do
        recorded="$(manifest_get "$manifest_file" "$key")"
        if [[ "$recorded" != "$value" ]]; then
            print -u2 "Native build manifest mismatch: $key was '$recorded', now '$value'."
            stale=1
        fi
    done

    if (( stale )); then
        print -u2 "Discarding $cesium_build (stale CMake configuration and vcpkg_installed binaries from a different toolchain or source pin)."
        print -u2 "vcpkg's download and binary caches under build/ are left in place."
        rm -rf "$cesium_build"
    fi
fi

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
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_TOOLCHAIN_FILE="$vcpkg_source/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET="$target_triplet" \
    -DVCPKG_HOST_TRIPLET=arm64-osx \
    -DVCPKG_OVERLAY_PORTS="$vcpkg_source/ports/openssl" \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_SYSROOT="$xros_sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$target_arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
    -DCMAKE_BUILD_TYPE="$build_type" \
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
vcpkg_install_lib="$cesium_build/vcpkg_installed/$target_triplet/lib"
absl_archives=("$vcpkg_install_lib"/libabsl_*.a(N))
if (( ${#absl_archives[@]} == 0 )); then
    print -u2 "No libabsl_*.a archives found under $vcpkg_install_lib; abseil was not installed by vcpkg."
    exit 1
fi
xcrun libtool -static -o "$vcpkg_install_lib/libEarthflightAbseil.a" "${absl_archives[@]}"

# The effective C++ standard and the compile definitions that affect the
# layout of types Cesium's public headers expose (glm's, mainly) are read
# back from CMake's own generated compile_commands.json rather than assumed,
# since Cesium's CMakeLists — not this script — is what actually decides
# them. Per-library "*_BUILDING" export macros are excluded: those are
# private to each static archive and irrelevant to a consumer.
cxx_standard="$(grep -m1 -o -- '-std=[A-Za-z0-9+]*' "$cesium_build/compile_commands.json")"
cxx_standard="${cxx_standard#-std=}"
abi_defines="$(grep -o -- '-D[A-Za-z0-9_]*' "$cesium_build/compile_commands.json" | sort -u | grep -v '_BUILDING$' | tr '\n' ' ')"
abi_defines="${abi_defines% }"

built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
    for key value in "${(kv)identity[@]}"; do
        print -r -- "${key}=${value}"
    done
    print -r -- "XCODE_VERSION=${xcode_version}"
    print -r -- "CXX_STANDARD=${cxx_standard}"
    print -r -- "ABI_DEFINES=${abi_defines}"
    print -r -- "BUILT_AT=${built_at}"
} > "$manifest_file"

print "Native build manifest written to $manifest_file"
print "  Xcode $xcode_version ($xcode_build), visionOS SDK $xros_sdk_version ($xros_sdk_build), C++ $cxx_standard"
