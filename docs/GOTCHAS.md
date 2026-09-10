# GOTCHAS.md — Earthflight

Everything here cost a session to find out. It is written as rules with reasons,
not as a history. If a change of yours seems to need one of these reversed, that
is the moment to stop and say so rather than to try it quietly.

Read the section that covers what you are about to touch.

---

## Swift 6 and actor isolation

The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a closure — including
one handed to an Objective-C API — is inferred `@MainActor` unless something forces
otherwise. Swift 6 emits a **hard runtime check** inside the bridged block thunk
where Swift 5 emitted none. A callback the system delivers on another queue no
longer races quietly; it traps:

```text
BUG IN CLIENT OF LIBDISPATCH: Assertion failed:
Block was expected to execute on queue [com.apple.main-thread (...)]
```

**So, before writing any Objective-C or system callback: read its header for the
delivery queue, and record the answer in a comment beside it.** A clean build
proves nothing about where a block runs.

The one exception is a block parameter the SDK declares `@Sendable`, which is
imported nonisolated.

### The contracts already established

| Callback | Delivery | Expressed as |
|---|---|---|
| `SFSpeechRecognizer.requestAuthorization` handler | header gives no main-queue guarantee, and it really does arrive elsewhere | `JumpTo.speechAuthorizationStatus` is `nonisolated` |
| `recognitionTask(with:resultHandler:)` handler | `SFSpeechRecognizer.queue` defaults to main and is never set | inferred main-actor |
| `AVAudioNode.installAudioTap` tap block | declared `@Sendable`; runs on the audio thread | nonisolated, no check |
| GameController element handlers | `handlerQueue` defaults to main and is never set | inferred main-actor |
| `GCControllerDidConnect` / `DidDisconnect` observers | registered `queue: .main` | `MainActor.assumeIsolated`, a *checked* assertion |
| The five `CesiumBridge` callbacks | main queue: two via `dispatch_async`, three synchronously from `updateTiles` | `NS_SWIFT_UI_ACTOR` on the block parameters |
| `MaterialParameters.Texture.Sampler.modify` | synchronous on the caller | inferred main-actor |

`CesiumBridge.tileDidFinishPreparing:` is deliberately **not** `NS_SWIFT_UI_ACTOR`.
It takes a mutex and resolves a Cesium promise, both safe from any thread;
claiming the main actor there would be a lie the compiler would then enforce.

### Two boundaries Swift will not let you simply assert

* **The controller connect/disconnect notifications.** `NotificationCenter`
  declares the observer block `@Sendable` and offers no main-actor-isolated
  alternative, so a non-Sendable `GCController` cannot cross out of it.
  `MainActor.assumeIsolated` does not help: what is diagnosed is the value
  crossing, not the isolation. The blocks therefore carry only the signal, and
  `reconcileBinding` re-reads `GCController.controllers()` on the main actor —
  which `GCController.h` asks callers to do alongside the notifications anyway.
  Release is decided by identity against that live array.
* **The audio tap.** Because the block is `@Sendable` it must not touch the
  main-actor recognition request. It copies each buffer, as it always did; a fresh
  copy is in its own isolation region and can be sent, so an
  `AsyncStream<AVAudioPCMBuffer>` carries it in order to a main-actor loop that
  appends. Nothing may be appended after `endAudio`, and a cancelled
  `AsyncStream` still hands back what it had buffered, so that loop checks
  cancellation itself.

### Measured facts, do not re-derive

* **`swiftc -typecheck` does not run region isolation.** "sending ... risks
  causing data races" is a SIL diagnostic, so a typecheck-only pass gives a false
  clean bill. Probe with `-emit-sil` or `-c`.
* **`NotificationCenter.MainActorMessage` traps on a background post.** It
  compiles cleanly for `GCControllerDidConnect`, but a runtime probe showed it
  SIGTRAPs when the notification is posted from a background thread, and which
  thread GameController posts on is unverified. Do not "modernise" the observers
  onto it.
* **Region isolation cannot check a global-actor-annotated task-group child that
  suspends.** `group.addTask { @MainActor in ... }` containing any `await` yields
  "pattern that the region-based isolation checker does not understand how to
  check. Please file a bug". `JumpTo.captureTranscript` therefore adds plain
  children that call main-actor methods, which states the same isolation. Recheck
  that diagnostic before putting the annotation back.
* **`MainActor.assumeIsolated` is a check, not a suppression.** It succeeds for a
  `queue: .main` observer whether the post came from the main thread or not, and
  traps rather than racing if that ever stops being true.

Do not reach for `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`
or `assumeIsolated(unsafe:)`. There are none in the project, and adding one hides
exactly the class of defect this section exists to catch.

### Auditing the whole app

To find every main-actor claim the runtime will check:

```sh
BIN=".../Build/Products/Release-xros/earthflight.app/earthflight"
xcrun otool -tvV "$BIN" > rel.s
```

For each line containing `_swift_task_isCurrentExecutor`, take the nearest
preceding label and `xcrun swift-demangle` it. Check every hit that is an
Objective-C or system callback against its header. Ignore
`__isolated_deallocating_deinit` hits, which are routine. Use the **Release**
binary: the Debug build is an `ENABLE_DEBUG_DYLIB` launcher stub, and the app code
lives in `earthflight.debug.dylib` beside it.

---

## glTF to RealityKit: the importer contract

This works. If a visual regression appears, first find which of these was broken.
Do not start by suspecting Google's geometry, skirts or imagery, or Cesium's LOD.

* glTF texture coordinates use an upper-left image origin. Apply
  `KHR_texture_transform` in glTF texture-coordinate space **first**, then convert
  for RealityKit with `v = 1 - v`. There is exactly one flip; do not add another
  and do not flip decoded image rows.
* Honour `TextureInfo.texCoord` and any `KHR_texture_transform.texCoord` override.
* Decode texture-coordinate accessors according to their declared component type
  and normalisation, preserving accessor and buffer-view byte offsets and strides
  through Cesium's accessor views.
* Keep the unsigned-byte, unsigned-short and unsigned-int index paths.
* Upload only the full-resolution base mip when Cesium stores several mip levels
  back-to-back in one image asset.
* Set RealityKit sampler address, minification, magnification and mip-filter modes
  from the glTF sampler rather than trusting RealityKit's defaults.
* Honour glTF `doubleSided` through RealityKit face culling.
* Keep the node, model, RTC, ECEF and local-ENU transform order as it is. Global
  maths stays in double precision; convert to `Float` only for the final local
  vertex payload.
* Keep the asynchronous tile-generation guard: a tile removed while its RealityKit
  resources are being prepared must not be installed afterwards.

### Tile textures

Google RGBA imagery goes into a no-flip, upper-left-row-order `CGImage` and then
through RealityKit's asynchronous `TextureResource(image:options:)`.

* **Do not restore the raw `TextureResource(dimensions:format:contents:)` upload.**
  It produced a pale white frame before every newly encountered texture became
  usable. This was isolated with constant cyan pixels: through the raw path they
  still flashed white, through the `CGImage` path they did not. The source pixels
  were never the problem.
* The `CGImage` is labelled **sRGB**, because glTF defines base-colour texels as
  sRGB. Labelling it `displayP3` suppresses the gamut conversion and pushes every
  saturated colour out towards the wider P3 primaries. RealityKit colour-manages
  into Display P3 itself.

---

## Tile selection, LOD and visibility

Cesium already does view-dependent selection, frustum culling and screen-space-error
refinement. Nearby tiles refine while distant ones stay coarse and can look nearly
flat; broad low-detail horizon coverage is expected and correct.

* Show only `tilesToRenderThisFrame`. Loaded or cached content is not
  automatically visible content.
* **Two view states go to Cesium at the same centre eye**: a 90-by-70-degree,
  1024-by-1024 detail view, and a 120-by-110-degree, 1-by-1 coverage view. Cesium
  culls against their union but takes the largest screen-space error, so the first
  keeps refinement pressure while the second covers the Vision Pro's periphery.
  The single 90-by-70 frustum left real gaps out at the edges. **Never set the
  coverage viewport to zero height** — cesium-native 0.64 treats that as a reason
  to bypass fog culling.
* Do not tune screen-space error, preload behaviour, cache limits or load
  concurrency because the visible area looks broad. Change them only for measured
  frame time, memory pressure or a visible defect on the headset.
* Do not classify tiles by distance or add a second LOD system.
* `maximumSimultaneousTileLoads` limits concurrent loading, not how many tiles are
  visible or cached. The Cesium cache it feeds is transient and in memory; there is
  no disk cache and none is wanted.

### The transition is an opaque readiness-gated handoff

* RealityKit meshes, textures, materials and disabled entities are all created
  through Cesium's asynchronous `prepareInLoadThread` future **before**
  `prepareInMainThread` makes a tile selectable. Partial or zero construction
  resolves as failure, never as covering geometry.
* `GoogleTileRenderer.publishSelectedAndRetireOutgoing` then enables the complete
  selected set and disables its predecessors as one uninterrupted main-actor scene
  change, with no `await` between visibility changes and no overlap timer.
* **`OpacityComponent` crossfade was rejected**: overlapping photogrammetry
  exposed the sky and the geometry behind tall structures through the fade.
* Retirement is derived from the difference between what the renderer is drawing
  and what Cesium selected this update, and happens only once the whole selected
  set is installed. Deriving it from `tilesFadingOut` instead is wrong: that list
  names a tile only on the single frame its overlap window elapses.
* Tile containers are identity children of `earthRoot`; primitive transforms keep
  their own ECEF/render-local anchors. Preparation and rebasing use the latest
  render frame, so Jump To stays coherent.

### Established facts about cesium-native 0.64

* `Tileset::updateViewGroup` permanently forces `enableFrustumCulling` and
  `enableFogCulling` to false whenever `enableLodTransitionPeriod` is true, which
  floods selection with tiles from right around the globe — about 90 tiles becomes
  about 215. Since the renderer no longer reads `tilesFadingOut`, the transition
  period buys nothing, so `lodTransitionsEnabled` is `false`.
* `TilesetOptions::forbidHoles` does not do what its doc comment promises. All
  three uses are in the culled branch of `visitTileIfNeeded`; it only makes culled
  tiles load and report upward. Do not re-trust that comment.
* `visitVisibleChildrenNearToFar` ANDs `allAreRenderable` across children but ORs
  `anyWereRenderedLastFrame`, so one already-rendered child switches
  `kickDueToNonReadyDescendant` off and the parent refines anyway, drawing the
  ready children and omitting the rest. `TilesetOptions` exposes no lever for this.
* **`Tile::isRenderable` is not "has content".** It is false for every `Done` tile
  that is unconditionally refined and has children — exactly Google's structural
  external-tileset nodes. Test `Tile::getState` against `Done` and `Failed`.
* **Never key renderer state on the `Tile` pointer.** Cesium destroys and
  reallocates `Tile` objects constantly while flying into new ground, so a recycled
  address would alias two live tiles. Identifiers are an atomic monotonic counter
  allocated during load-thread preparation.
* A tile referenced by an `IntrusivePointer` counts as content-referenced and
  cannot be unloaded, so holding `Tile::ConstPointer` is a valid way to keep
  content alive while it is still drawn.

### Blind alleys, already measured

* Earthflight is not hiding anything too early, and it never removes anything
  visible. Both were instrumented across many flights and neither fired; the
  diagnostics were then deleted.
* Cesium is not selecting unloaded tiles. Counts of selected tiles that were not
  `Done`/`Failed`, were external content, or had no identifier all read zero
  throughout flight. Every tile Cesium selects, Earthflight draws.
* Waiting more frames does not help. Extra opaque overlap produced no improvement
  and did cause intersecting-LOD artefacts.
* Covering each uncovered sibling with its nearest drawable ancestor changed
  nothing visible.
* Keeping the whole ancestor chain of every selected tile on screen does close
  gaps, but at up to 96 extra tiles against a render set of 90 to 236 it starved
  tile loading badly. Worse than the defect.
* Never retiring anything is much worse still: large areas stay stuck on coarse
  tiles. Retirement is doing real work.
* A completed GPU copy of each new raw texture was not a presentation barrier — it
  still flashed, and cost preparation time and transient memory.
* Counting camera-visible children that are neither selected nor an ancestor of
  anything selected reports two to nine such gaps on essentially every update,
  including updates with nothing installing. The measurement is real but has known
  false positives, because Google's bounding volumes are loose. Do not treat a
  rebuilt version of it as evidence on its own.

**The remaining seam.** In steep mountainous terrain a thin sky sliver can appear
where two adjacent tiles at different LODs do not share an identical boundary.
That is geometric, not a texture or readiness fault, and it is low priority. If it
is ever worth addressing, reproduce one seam and look only at the two drawable
boundary meshes and their refinement relationship. Do not revive the global
ancestor shell to hide it.

---

## Coordinates, precision and the flight envelope

* Planetary position is WGS84 ECEF in double precision. RealityKit entities stay
  near a local origin in ordinary metre-scale floats.
* The render origin rebases after 50 km of ECEF displacement, deriving a fresh
  local east/north/up frame from the craft position. The renderer receives the new
  ECEF-to-render-local transform on each rebase.
* Ellipsoid height is the authoritative altitude. The speed reference is
  deliberately separate from terrain height or height above ground.
* **Heights above the geoid and above the ellipsoid are not interchangeable.**
  Google Elevation returns mean sea level `H`; the bundled Cesium `WW15MGH.DAC`
  EGM96 grid gives `N`; the ellipsoid height is `H + N`.
* Horizontal integration steps along the local tangent frame and then reconstructs
  ECEF at the intended ellipsoid height, so chord-shortening cannot add altitude.
* **The integration step limit is angular, not a flat distance.** A flat 10 km step
  is fine at the surface but the movement itself grows with altitude, so the two
  multiply: ten seconds of pitched climb once reached 899,106 Cesium conversions in
  a single frame, which took the frame rate and with it the controls, the tile
  updates and the sky's own rebuild. The limit is `10 km / 6,371 km` of arc scaled
  by geocentric radius — identical at the surface, and flat at about 115 steps per
  frame at any altitude. `FlightState.integrationStepCount` exists so a test can
  pin it.
* **Height is clamped, in `integrate`, the single place flight changes it.**
  Because speed scales with altitude, a pitched-over full stick makes height feed
  its own growth: at the 80-degree pitch limit it e-folds every 0.56 seconds with
  boost. Render-local positions are Float, and one unit in the last place is 47
  metres at the ceiling but 206 km far above it, where the globe comes apart.
  `EarthflightTuning.maximumEllipsoidHeightMeters` is the Moon's mean distance;
  the Earth is under two degrees wide there and the same pitched trick brings the
  craft back in under two seconds, so it is not a trap.
* **Capping horizontal speed instead was considered and rejected**: it would change
  the accepted feel at every altitude to fix something that only happens at the top.
* Comment coordinate work directly: source frame, destination frame, units,
  handedness, multiplication order, and whether a transform is camera-to-world or
  world-to-camera. Do not hide transforms behind generic matrix helpers with
  ambiguous names.

---

## Flight feel

The feel is accepted. These are the shapes that produce it.

* Heading, pitch and roll are stored as independent control state and the
  orientation basis is rebuilt explicitly from them. With roll at zero, yaw and
  pitch together — including a diagonal right stick — must leave the horizon
  level. **Do not restore incremental `yaw * orientation * pitch` accumulation.**
* Right-stick click is a hard orientation reset to the launch heading, pitch and
  roll. It preserves geographic position and movement input, and clears the
  steering tail; a reset that immediately turned back off level would be wrong.
* Both sticks share one `StickReleaseDecay` value, so its rules are stated once.
  Movement and steering have their own durations in the tuning file, steering's
  being the shorter. What coasts when steering is released is the **turn rate**, so
  the craft eases out of a turn rather than stopping dead. Setting a duration to
  zero disables the effect and bypasses its state entirely. Any new deliberate
  input cancels a decay.
* Per-axis release state keeps the strongest deliberate sample, because the Switch
  Pro stick's opposite-direction recentre rebound would otherwise reverse a
  same-direction release tail.
* Button roll is deliberately unaffected by release decay.

---

## Sky

One inward-facing unlit sphere centred on the craft, textured with a
one-dimensional gradient in the angle from local up, drawn with
`faceCulling = .front`. `SkyDome.swift` holds it; `EarthflightTuning` holds the
palette.

* **One dimension is enough.** From any point above a sphere the ground, the
  horizon ring and the atmosphere's bright limb are all rotationally symmetric
  about local up, so a vertical gradient on the texture *is* the picture, at every
  altitude. No second axis, no shader, no cube map. `MeshResource.generateSphere`
  maps V linearly to polar angle and a chord's midpoint bisects the arc, so the
  gradient stays accurate on a coarsely tessellated sphere.
* **Air mass is the only scalar.** `SkyAtmosphere.ray` returns air mass along a ray
  in units of the sea-level vertical column, plus whether the ray reaches the
  Earth. Nothing in the palette mentions altitude. The horizon moves down the sky
  as the Earth shrinks without anything computing where it is: rays simply start
  reaching the ground. Rays that do reach it show the sandy terrain-gap fill with
  scattered colour laid over as haze, and the two branches agree at the horizon
  because a grazing ray collects almost as much air as one just above it.
* The model is an exponential atmosphere, scale height 8,500 m, top 120,000 m,
  sphere radius 6,371,000 m. Ellipsoid height is used directly as height above that
  sphere: self-consistent, and it keeps WGS84 flattening out of it, which moves the
  horizon by hundredths of a degree — well under one texture row.
* **The dome grows with altitude.** `SkyDome.radiusMeters` returns
  `max(9,000,000, 1.5 * sqrt(d² - R²))`, the horizon tangent distance being the
  farthest visible point of the Earth; otherwise the fixed radius would
  depth-occlude the globe once you are far enough out to see all of it. Below about
  3,000 km the fixed radius wins, so low flight renders exactly the accepted
  geometry. The mesh keeps the fixed radius and growth is applied as entity scale.
  **This is the one part that could still fail on hardware** — the accepted build
  proves the far plane is at least 9,000 km, not that it is unbounded. If the globe
  or sky clips at extreme altitude, suspect the far plane, not the gradient.
* **The frame is the rebuild throttle, not the height threshold.** At most one
  rebuild starts per scene update, because `update` runs once a frame and
  `isRebuilding` blocks a second. The 25 m threshold only stops pointless work
  while hovering; it was 500 m once, and climbing 500 m from 1,000 m moved some
  texels by 63 of the 255 available levels, which the owner saw as the sky
  stepping. That cadence is affordable because `SkyGradient.raysPerRow` is one per
  row below 10,000 km and four above, where most rays miss the atmosphere and
  return immediately.
* **Two independent causes of banding, and the fix for each.** Straight lines
  between palette stops change slope abruptly and the eye turns that into a Mach
  band; `SkyGradient.scatteredColour` joins the stops with a monotone cubic
  (Fritsch-Carlson tangents), which took the worst slope ratio from 8.6 to 1.7.
  The stops are still hit exactly, so every tuned colour appears where it was
  tuned. **Do not go back to straight lines to save fifteen lines of code.**
  Separately, eight-bit quantisation held one blue value for over a hundred rows
  near the zenith; `SkyGradient.dither` adds plus or minus half a level per texel
  before rounding, from a hash of the texel rather than a fresh random number, so
  the pattern is identical in every rebuild and cannot sparkle during a climb.
  The ray march was measured and is *not* a banding cause; raising
  `marchSampleCount` was tried and correctly reverted.
* The gradient texture must stay **unmipmapped**: mips would average the dither
  away, and the dome is always magnified.
* Upload uses `TextureResource.replace(using:options:)`, the CGImage path. Do not
  switch it to the raw-contents path — see the tile-texture section for what that
  does.
* `SkyAtmosphere` and `SkyGradient` are `nonisolated` on purpose, and the pixels
  are computed in a `Task.detached`, so the march never runs on the render actor.
  A climb allocates a fresh 256 KB buffer and CGImage roughly once a frame; that is
  accepted rather than pooled.
* `SkyDome.update` orients the entity to `FlightState.renderLocalFromCraftTangent`,
  the craft's current tangent frame. Leaving it at identity silently pins the
  gradient's zenith axis to the render frame's fixed axes, which match current
  geodetic up only at the point that last set the render origin — about 0.45
  degrees out by the far end of a rebase interval, then snapping back.
* `EarthflightTuning.skyAirMassColourStops` is the whole palette. Tune there.

---

## Stars

Around a thousand white quads on a sphere at 95 per cent of the dome's radius,
added as a child of the dome so they inherit its craft-centred position and its
altitude-driven scale.

* **The field is anchored to ECEF, not to the render frame.** Anything fixed in
  render-local jumps in world orientation by up to half a degree at every 50 km
  rebase and rotates continuously in between. The sky gradient is symmetric only
  about its own up axis, so this shifts it too — just smoothly enough not to be
  noticed, unlike pinpoint stars, which would visibly pop.
  `StarField.earthAnchoredOrientation` writes the render-local-from-ECEF rotation
  onto the field's parent to cancel it. Inverting that rotation is the easy
  mistake, which is why a test checks one star direction landing on the same ECEF
  direction from two very different render frames.
* Because the dome now carries its own rotation to geodetic up, the field's
  orientation must cancel **both**, via
  `skyOrientation.inverse * earthAnchoredOrientation(...)`, or the stars are
  carried by the dome's rotation on top of their own and rotate twice.
* Stars fade with the same air mass the gradient uses: invisible at sea level,
  fully out past the Karman line. There is no day, no night and no separate mode.
  Below a threshold the whole field is disabled so a thousand transparent quads
  stay out of ordinary low flight.
* **Twinkling is done in banks, not per star.** The stars are split across a few
  meshes whose material opacity breathes on different periods. Animating a thousand
  points individually needs a shader, and visionOS has no `CustomMaterial`. Every
  star in a bank breathes together, so the base brightness is deliberately high — a
  deeper swing reads as banks rather than as twinkling. Real stars do not twinkle in
  vacuum anyway.
* Each star carries one shared 32-by-32 `Opacity` texture with a soft shoulder.
  Untextured quads were visibly square on the headset. That texture **is**
  mipmapped, unlike the sky gradient: a star one or two pixels across minifies a
  long way and would otherwise sample an arbitrary texel and flicker as the head
  turns. The cost is that the smallest stars sample the falloff's mean, so
  `starTwinkleBaseBrightness` compensates. Base plus amplitude must stay at or
  below 1.
* Two accepted consequences: stars are drawn over the sandy terrain-gap fill, so
  they can show through a hole in the tiles below the horizon (loaded tiles are
  opaque and nearer, so they occlude correctly); and the fade is global rather than
  per direction, so stars near the bright limb are not washed out individually.

---

## Head-up display

Two marks in `HeadUpDisplay.swift`: a ring on the nose axis and a bar in the local
horizontal plane with a gap the ring sits in. They exist so the owner can tell,
without guessing, which way the left stick will move the craft.

* The craft's pose in the immersive world never changes — `earthRoot` moves — so
  "straight ahead" is a fixed world direction, the ring is a static entity, and
  only the bar is touched per frame. The display hangs off `content`, not off
  `earthRoot`.
* Everything is in the craft's own frame, so the bar needs craft attitude and
  nothing else: no render frame, no floating origin, no ECEF. Heading cancels out
  exactly in `HeadUpDisplay.horizonOrientation`, which is the geometric statement
  of the fact that yawing does not move the horizon within the view. The
  projection cannot degenerate because pitch is clamped to 80 degrees.
* **The bar tracks local horizontal, not the true visible horizon**, which dips
  below it by `acos(R / (R + h))` — 1 degree at 1 km, 10 degrees at 100 km.
  Tracking the true horizon would hold the bar off the ring at startup and, higher
  up, draw a straight line tangent to a small round limb. Local horizontal is what
  an attitude indicator shows and what "level" means here. **Do not "fix" this
  without asking.**
* Each arm is an **arc of the horizontal circle**, not a flat bar. Every point on
  an arc lies exactly on the horizon however long the arm is; a flat bar would
  touch it only at the centre.
* The marks are 1,000 m away and sized in **angles, not metres**. The craft origin
  is a fixed world point but the wearer's head is not: at two metres, leaning half
  a metre would swing the ring 14 degrees off the very axis it exists to report. At
  a kilometre that lean is 0.03 degrees and the marks are effectively collimated,
  as a real head-up display is. Do not move them closer without re-deriving that.
* `readsDepth` and `writesDepth` are both false, so terrain never buries the
  marks. If they are ever occluded on hardware, the next lever is
  `ModelSortGroupComponent` with a post depth pass, not moving them nearer.
* They are hidden while a Jump To is active, because the card is billboarded at the
  same azimuth and the marks would be drawn over its text. That is simpler than
  sorting them.
* Both marks are plain generated geometry with no texture. If the edges ever crawl
  on hardware, the fix is `StarField`'s soft-edged opacity texture, not more
  segments.

---

## Jump To

`+` starts one voice query; there is no keyboard entry, result list, confirmation
or "did you mean".

* Only the press-down transition of `buttonMenu` starts an operation.
* Jump To pauses only `FlightState.advance`. Head tracking, Cesium selection, the
  tile lifecycle, the sky and attribution all continue. A fully resolved
  destination crosses to the scene update as one pending value, where
  `FlightState.jump` and `setRenderFrame` happen before the next Cesium view
  update.
* MapKit receives the exact trimmed transcript with no region, and
  `response.mapItems.first` wins. Ground height comes from one Google Elevation
  request as mean sea level, corrected to the ellipsoid with the bundled EGM96
  grid, plus a fixed 1,000 m clearance. No result simply closes the presentation.
* A completed jump performs the same complete orientation reset as a right-stick
  click, preserves active controller input, clears any movement tail, centres a
  fresh render frame at the new ECEF position and sets the speed-reference ground
  datum. It does not recreate the tileset or renderer resources.
* **The `SpeechAnalyzer` capture path is blocked on visionOS**:
  `AVCaptureDevice.default(for: .audio)` returns no device on hardware, and
  `AVCaptureDevice.DeviceType.microphone` is unavailable to visionOS. Use the
  single `SFSpeechRecognizer` plus `AVAudioEngine` path, with
  `installAudioTap` and a copied mutable PCM buffer. Do not reintroduce both
  recognition paths in parallel.
* **A SwiftUI `.overlay` outside a full immersive `RealityView` does not present on
  hardware.** Jump To status is a persistent `RealityView` `Attachment`,
  billboarded in front of the wearer and transparent while idle. Do not replace it
  with an outer window overlay.

---

## Attribution

* Use Cesium Native's `CreditSystem` snapshot as the source of dynamic credits: it
  already aggregates what the current render set requires. Display its unique
  sorted current credits in full, without deliberate truncation. Do not assume one
  static copyright string is enough — Google's per-tile attribution arrives in
  glTF `asset.copyright`.
* Use Google's official, unmodified outlined Google Maps logo asset over the
  rendered imagery, within Google's required 16–19 point height range, kept
  visibly associated with the credits and persistently visible. Do not recreate it
  as text or artwork while the asset remains usable.
* A bounded transient Cesium cache is fine. No offline city exporter or persistent
  tile archive.

---

## Build and test

* The physical device is the only buildable and testable destination. The
  simulator fails at the link step because the native build script only configures
  the device `XROS.sdk` and the `arm64-visionos` vcpkg triplet. This is by choice.
* `build-for-testing` in Release fails and always has: `@testable import
  earthflight` cannot resolve because `ENABLE_TESTABILITY` is off in Release.
  Tests run in Debug. Do not chase it.
* The `earthflight` target's first build phase compares the active toolchain and
  the pinned Cesium/vcpkg commits against the native build manifest and fails with
  the exact rebuild command if anything is stale. If it fires, rebuild the native
  dependencies rather than working around the check.
* Remaining expected compiler warnings: documentation warnings from Cesium's own
  headers, and one `-Wunused-getter-return-value` in `CesiumBridge.mm`. Anything
  else is yours.
* BUILDING.md holds the pinned commits, toolchain identity, the merged
  `libEarthflightAbseil.a` explanation and the full commands. Read it before
  touching the native build; it was expensive.
