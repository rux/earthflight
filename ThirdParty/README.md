# Cesium Native for visionOS

`cesium-native` is pinned as a Git submodule at upstream v0.64.0 commit
`80a22ff4337c5b7057cff53d0055045c15c6d350`. `vcpkg` is pinned at the
manifest baseline commit `56bb2411609227288b70117ead2c47585ba07713`.

Install current CMake and Ninja, then build the physical visionOS arm64 static
libraries with:

```sh
scripts/build-cesium-visionos.sh
```

The script applies the two small patches in `patches/`, builds with the Xcode
27 `xros` SDK and installs headers and libraries under the ignored directory
`build/cesium-visionos/install`. Cesium tests, clang-tidy and documentation are
not built.
