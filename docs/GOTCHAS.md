# GOTCHAS.md — Earthflight

Facts that cost real time to learn and that the code cannot show by itself:
behaviour of Cesium, RealityKit, visionOS and Swift that is undocumented or
misdocumented, and approaches that were built, measured and abandoned. The code's
own comments explain how the code works; read them too.

If a change seems to need one of these reversed, stop and say so rather than
trying it quietly.

---

## Swift 6 and actor isolation

With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, a closure handed to an
Objective-C or system API is inferred `@MainActor`, and Swift 6 checks that at
run time inside the bridged block. A callback delivered on another queue does not
race; it traps:

```text
BUG IN CLIENT OF LIBDISPATCH: Assertion failed:
Block was expected to execute on queue [com.apple.main-thread (...)]
```

A clean build proves nothing about where a block runs. **Before writing any such
callback, read its header for the delivery queue and record the answer in a
comment beside it.** Block parameters the SDK declares `@Sendable` are the one
exception: they import nonisolated.

* `SFSpeechRecognizer.requestAuthorization` gives no main-queue guarantee and
  really does call back elsewhere.
* `swiftc -typecheck` does not run region-isolation checking ("sending ... risks
  causing data races" is a SIL diagnostic). Probe with `-emit-sil` or `-c`.
* `NotificationCenter.MainActorMessage` compiles for `GCControllerDidConnect`
  but SIGTRAPs when the notification is posted from a background thread, and
  which thread GameController posts on is unknown. Do not "modernise" the
  controller observers onto it.
* `group.addTask { @MainActor in ... }` containing any `await` produces a
  region-isolation "does not understand how to check" error. Add plain children
  that call main-actor methods instead.
* There are no `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency` or
  `assumeIsolated(unsafe:)` in the project. Adding one hides exactly the defect
  this section is about.

**Auditing every runtime main-actor check.** Disassemble the **Release** binary
(Debug is an `ENABLE_DEBUG_DYLIB` stub; the code is in `earthflight.debug.dylib`):

```sh
xcrun otool -tvV ".../Release-xros/earthflight.app/earthflight" > rel.s
```

For each `_swift_task_isCurrentExecutor` call, demangle the nearest preceding
label with `xcrun swift-demangle` and check any Objective-C or system callback
against its header. `__isolated_deallocating_deinit` hits are routine.

---

## RealityKit and visionOS

* **`TextureResource(dimensions:format:contents:)` flashes one white frame before
  every new texture on the M2 Vision Pro**, even with constant test pixels and
  even after a completed GPU copy. The `CGImage` path does not. This applies to
  tiles and the sky alike.
* **A SwiftUI `.overlay` on the full immersive `RealityView` is not usable.** For
  Jump To it never presented on hardware; for the attribution it presented
  somewhere it could not be positioned and was seen from behind, reading
  backwards. Put anything visible in a `RealityView` `Attachment`.
* **The `SpeechAnalyzer` capture path does not work on visionOS hardware.**
  `AVCaptureDevice.default(for: .audio)` returns nil and
  `AVCaptureDevice.DeviceType.microphone` is unavailable. Use `SFSpeechRecognizer`
  with `AVAudioEngine`.
* **visionOS has no `CustomMaterial`.** Anything per-vertex or per-instance
  animated (star twinkle, for instance) has to be done with separate entities and
  `OpacityComponent`.
* An `OpacityComponent` crossfade between tile LODs was tried and rejected:
  overlapping photogrammetry shows the sky and hidden geometry through the fade.
* The sky dome grows to `max(9,000 km, 1.5 × horizon distance)`. The headset has
  only shown that the far plane is at least 9,000 km, not that it is unbounded. If
  the globe or sky clips at extreme altitude, suspect the far plane.

---

## glTF import

If tiles look wrong, suspect the importer before Google's geometry, skirts or
imagery, or Cesium's LOD; every past visual defect was ours.

* Apply `KHR_texture_transform` in glTF texture space first, then flip with
  `v = 1 - v`. There is exactly one flip. Do not add another, and do not flip
  decoded image rows.
* glTF base-colour texels are sRGB. Labelling the `CGImage` Display P3 skips
  RealityKit's conversion and oversaturates every strong colour.

---

## Cesium Native 0.64

* **`Tile::isRenderable` does not mean "has content".** It is false for every
  `Done` tile that is unconditionally refined and has children, which is exactly
  Google's external-tileset nodes. Test `Tile::getState` against `Done` and
  `Failed`.
* **`forbidHoles` does not do what its doc comment says.** All three uses are in
  the culled branch of `visitTileIfNeeded`; it only makes culled tiles load and
  report upward.
* **`enableLodTransitionPeriod = true` permanently disables frustum and fog
  culling** in `updateViewGroup`, taking a selection of about 90 tiles to about
  215 from around the globe.
* **`tilesFadingOut` cannot drive retirement.** It names a tile only on the single
  frame its overlap window ends. Retire by diffing what is drawn against what is
  selected.
* `visitVisibleChildrenNearToFar` ANDs `allAreRenderable` but ORs
  `anyWereRenderedLastFrame`, so one already-rendered child lets the parent refine
  with some children missing. `TilesetOptions` has no lever for this.
* **Never give Cesium a zero-height viewport**; it then bypasses fog culling.
* Cesium takes the largest screen-space error over all views, whether or not a
  tile is visible in them. A second wide, low-resolution "coverage" view adds
  nothing over one view with the wide cone.
* Fog culling does not touch visible ground: with the default table it culls only
  beyond the horizon. Coarse distant ground is screen-space error, not fog.
* Any HTTP error fails a tile for good, and Cesium never retries a failed tile
  while it stays selected. That is why a Google 429 must never reach Cesium: the
  freed slot is refused in turn, and every tile requested until the quota
  recovers becomes a permanent hole.
* Google's rate limit, not Cesium, caps loading. With
  `maximumSimultaneousTileLoads` at 10 or more the owner could provoke 429s; at 8
  they could not.

### Tile gaps: blind alleys already measured

* Earthflight neither hides tiles too early nor removes anything visible, and
  Cesium never selects an unloaded tile. All three were instrumented across many
  flights and never fired.
* Waiting more frames before switching LOD made no improvement and caused
  intersecting-LOD artefacts.
* Covering uncovered siblings with their nearest drawable ancestor changed
  nothing visible.
* Keeping every selected tile's ancestor chain on screen closes gaps, but adds up
  to 96 tiles to a render set of 90–236 and starves loading. Worse than the
  defect.
* Never retiring anything leaves large areas stuck on coarse tiles.
* Reordering the load queue nearest-first (built through `TileLoadRequester`)
  made no visible difference: Google's rate limit caps how many tiles arrive, not
  which.
* Counting camera-visible children that are neither selected nor an ancestor of
  anything selected reports two to nine "gaps" every update, even when idle,
  because Google's bounding volumes are loose. Do not treat it as evidence alone.

**The remaining seam.** On steep terrain a thin sky sliver can appear where two
adjacent tiles at different LODs do not share an edge. It is geometric and low
priority. If it is ever worth fixing, reproduce one seam and study only those two
meshes. Do not revive the ancestor shell.

---

## Flight and coordinates

* **Do not restore incremental `yaw * orientation * pitch` accumulation.** Yaw
  and pitch together, including a diagonal right stick, must leave the horizon
  level with roll at zero; only rebuilding the basis from stored heading, pitch
  and roll does that.
* A release fade must start from the stick's last value, not the strongest point
  of the gesture. Fading from the peak made a slow, hand-eased release kick back
  to nearly full turn rate as it reached centre.
* Cesium's `sampleHeightMostDetailed` is not a cheap ground probe: it forces
  detailed tiles to load, and each passes through the renderer's preparation,
  building RealityKit meshes on the main thread for tiles never shown.

---

## Sky

* Straight lines between palette stops cause Mach bands. The monotone cubic took
  the worst slope ratio from 8.6 to 1.7; do not go back to save a few lines.
* The ray march is not a banding cause. Raising `marchSampleCount` was tried and
  reverted.

---

## Giant mode

Giant mode is one uniform scale on `earthRoot` about the craft origin, and its
correctness depends on not compensating for it anywhere else.

* Do not scale `maximumScreenSpaceErrorHeadsetPixels`, the viewport or geometric
  error: directions from the origin are unchanged, so Cesium's error is already
  right.
* The head offset reaching Cesium grows with size. That is correct. Feeding
  Cesium the craft position instead would make rendering and selection disagree.
* Do not add a size term to flight speed. Apparent speed does not change with
  size; if flight looks slower when large, the scale has stopped acting about the
  craft origin.

---

## Head-up display

* The marks hang from the wearer's head position, with the craft's orientation.
  Do not anchor them to the craft origin again: a seated wearer's eyes are some
  30 cm below it, and at any distance near enough to matter that swings the ring
  well off the nose.
* Each mark's distance comes from the ground it covers and shrinks with the
  world. A fixed distance, the original 1,000 m, puts the marks far behind the
  ground in giant mode, where they are seen double against it.
* The ground is a sphere at the height last measured below the craft. A true
  ray cast down the nose was considered and not built: Cesium tests every
  triangle of every tile the ray crosses, on the main thread, and a level ray
  over a city crosses many. If steep relief makes the ring sit visibly off the
  surface in giant mode, that is the next step, and it needs measuring first.

---

## Attribution

Google's terms, not taste:

* Use Google's official, unmodified outlined Google Maps logo asset, 16–19 points
  high, persistently visible and kept with the credits. Do not redraw it.
* Show Cesium's `CreditSystem` snapshot of current credits in full, untruncated.
  Per-tile attribution arrives in glTF `asset.copyright`; one static copyright
  string is not enough.

---

## Build

* Cesium's and vcpkg's headers are in `SYSTEM_HEADER_SEARCH_PATHS` to silence
  their doc-comment warnings. The build is otherwise warning-free, so any warning
  is new.
* If the toolchain-identity build phase fails, rebuild the native dependencies as
  it says; do not work around the check. BUILDING.md has the details.
