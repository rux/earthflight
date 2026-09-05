#!/bin/zsh
#
# Shared helper for reading the native-build manifest at
# build/cesium-visionos/build-manifest.txt. Sourced by both
# scripts/build-cesium-visionos.sh, which writes the manifest after a
# successful native build, and scripts/check-native-toolchain.sh, the Xcode
# build phase that reads it — so the two can never disagree about its format.
#
# The manifest itself is flat "KEY=VALUE" lines, one per fact, deliberately
# not JSON: both consumers are plain zsh and reading a line with sed needs no
# extra dependency.

manifest_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    sed -n "s/^${key}=//p" "$file" | tail -1
}
