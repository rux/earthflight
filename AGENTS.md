
# AGENTS.md — Earthflight

## Mission

Build a private, single-user visionOS application called **Earthflight** for:

* one original M2 Apple Vision Pro;
* one Nintendo Switch Pro Controller;
* one technically capable owner running and repairing the app from Xcode.

The app exists for one purpose: fly freely through Google’s photogrammetric 3D Earth data using conventional game-controller flight controls while looking around independently with the user’s head.

This is a personal experimental instrument, not a commercial product, reusable SDK, portfolio architecture exercise or distributable application.

The installed SDK and compiler are authoritative. Do not “correct” beta-27 code merely because remembered Xcode 26 APIs differ. Your knowledge cut-off (early 2026) is earlier than the SDK (August 2026)

The successful experience is:

1. Launch the app directly into a full immersive space.
2. Google Photorealistic 3D Tiles appear around the user.
3. The Nintendo Switch Pro Controller moves a virtual craft/camera through the world.
4. Head movement changes only where the user looks. It never changes flight direction, velocity or orientation.
5. Pressing the physical `+` button opens a tiny voice-driven “Jump to” interface.
6. The user speaks a location.
7. The first MapKit search result wins without confirmation or disambiguation.
8. The user is moved to approximately 1,000 metres above the ground at that location.
9. Google’s required attribution remains visible.
10. A minimal blue-gradient sky dome replaces an otherwise black background. Nothing else is added.

## Project posture: deliberately raw

Optimise for the shortest understandable path to a satisfying result on this one device.

Prefer:

* direct code;
* a few small concrete types;
* ordinary functions;
* local state;
* Swift concurrency where it is naturally required;
* `print`;
* `assert`, `precondition` and `fatalError`;
* force unwraps where the project’s fixed assumptions make them honest;
* manual validation on the physical headset;
* small commits after working milestones.

A crash followed by fixing the defect and relaunching is acceptable.

Do not add user-facing recovery flows, controller-selection UI, retry frameworks, diagnostics dashboards, settings screens or defensive machinery for configurations that do not exist.

### Explicitly prohibited unless the owner later asks for them

Tests are opt-in. Do not add or expand tests unless the owner explicitly requests them. When requested, add the smallest focused regression test to the existing test target. Do not create another test target, fixtures, mocks or test architecture unless the owner specifically asks for those too.

Do not create:

* unrequested unit tests;
* unrequested UI tests;
* additional Swift Testing or XCTest targets;
* unrequested test fixtures;
* unrequested mocks;
* snapshot tests;
* CI;
* dependency-injection containers;
* invented Swift protocols;
* factories;
* repositories;
* coordinators;
* service locators;
* MVVM layers;
* TCA;
* Clean Architecture;
* generic networking layers;
* generic caching layers;
* persistence;
* databases;
* analytics;
* telemetry;
* feature flags;
* remote configuration;
* onboarding;
* tutorials;
* accessibility input alternatives;
* localisation;
* multiple user profiles;
* multiple-controller support;
* keyboard controls;
* hand-tracking controls;
* custom pinch or gesture controls;
* game mechanics;
* scores;
* achievements;
* POIs;
* road labels;
* multiplayer;
* reusable frameworks;
* SDK extraction;
* speculative abstractions;
* “future-proofing” code.

Do not introduce third-party Swift packages except where genuinely necessary to compile and integrate Cesium Native and its required dependencies.

Do not create a folder hierarchy merely to classify seven files.

Do not create empty types or layers in anticipation of later work. Add a file only when the current milestone requires code in it.

### Simplicity does not excuse incorrect systems code

The following still require care:

* C++ and Swift resource ownership;
* threading;
* RealityKit entity lifetime;
* tile visibility;
* texture and mesh lifetime;
* cancellation of obsolete work where necessary;
* geographic coordinate transforms;
* floating-point precision;
* floating-origin rebasing;
* Google attribution;
* API-key handling;
* avoiding unbounded memory or persistent tile caching.

Be ruthless about product complexity, not careless about rendering correctness.

### Physical Vision Pro tool limitation

The coding agent cannot currently use its device-interaction screenshot / accessibility-hierarchy / interactive-session service with the physical Apple Vision Pro.

That service may report support for iOS, watchOS and tvOS 27+ simulators while
rejecting visionOS hardware. Treat this as a known tooling limitation, not as a
project, signing, device-pairing or visionOS configuration problem.

Therefore:

* do not repeatedly probe the device-interaction service for Vision Pro support;
* do not spend time looking for an alternative screenshot/hierarchy session
  through that service;
* do not attempt to fix Earthflight, Xcode, signing or deployment settings merely
  because that service rejects the headset;
* do not leave a nonexistent interaction session open or wait for one to appear;
* do not claim that visual appearance, controller feel, immersive placement,
  attribution position, LOD transitions or other headset-visible behaviour has
  been verified by the agent.

Xcode build/deployment facilities may still be usable independently where the
current environment exposes them. Use those normally when available.

For anything requiring visual or experiential validation on the physical
Vision Pro, build the project and give the owner a concise manual test procedure.
The owner is the authoritative observer for:

* immersive visual correctness;
* controller feel;
* head-tracking behaviour;
* LOD transitions and blinking;
* sky appearance;
* attribution placement;
* performance, smoothness and comfort.

Do not search for speculative non-interactive screenshot or hierarchy routes
unless a concrete new capability is explicitly exposed by the current tools.


## Fixed technical decisions

These decisions are settled. Do not re-open them without a concrete build, API or performance blocker.

### Application shell

Use:

* Swift;
* SwiftUI;
* one `ImmersiveSpace`;
* full immersion;
* `RealityView`;
* RealityKit;
* exactly one application target.

Do not use Unity.

Do not begin with Metal or Compositor Services. RealityKit has already been demonstrated with this data on the original M2 Vision Pro generation. Move to a custom Metal renderer only after measuring a specific RealityKit limitation that blocks acceptable operation.

No authored Reality Composer Pro scene or asset package is needed. The content is streamed and generated at runtime.

### Earth data

Use Google Map Tiles API **Photorealistic 3D Tiles**.

Google exposes the data as standard OGC 3D Tiles containing glTF content for use by compatible custom renderers.

Do not use:

* Apple Flyover data;
* private Apple mapping frameworks;
* reverse-engineered Apple C3M/C3MM data;
* the old reverse-engineered Google Rocktree endpoints;
* scraped Google Earth traffic;
* exported offline city meshes.

Apple frameworks are used for the application, but Apple does not provide the required public raw photogrammetric mesh stream. Google does.

### Tile runtime

Use current upstream **Cesium Native** for:

* tileset traversal;
* view-dependent selection;
* level of detail;
* frustum culling;
* asynchronous tile loading;
* glTF parsing;
* tile caching and eviction.

Cesium Native is not the renderer. It supplies selected in-memory glTF content to the RealityKit integration.

Use Google’s root tileset directly. Do not introduce Cesium Ion unless direct Google access proves concretely incompatible with current Cesium Native.

The root is conceptually:

`https://tile.googleapis.com/v1/3dtiles/root.json?key=YOUR_API_KEY`

### Native-language boundary

Cesium Native is C++. Keep the Swift/C++ boundary narrow and concrete.

The default approach is one small Objective-C++ bridge using `.h` and `.mm` files. Direct Swift/C++ interoperability is acceptable only when the current Xcode implementation is demonstrably smaller and less awkward.

Do not create a separate framework target.

Do not expose Cesium template-heavy types throughout Swift.

Do not attempt to turn the bridge into a reusable mapping library.

### Toolchain transitions

After changing Xcode or visionOS versions, especially when moving from a beta
toolchain to a release toolchain:

1. do not reuse Cesium Native, vcpkg or other native binaries produced by the previous Xcode toolchain;
2. confirm that `DEVELOPER_DIR` selects the intended full Xcode installation, not `/Library/Developer/CommandLineTools`;
3. rebuild the project-local native dependencies from their pinned source revisions;
4. rebuild Earthflight;
5. repeat the current milestone's physical-headset smoke test before beginning the next milestone;
6. update the recorded known-good Xcode, SDK, compiler and native-build details.

Do not add compatibility layers for old beta toolchains. Support the currently installed authoritative toolafchain.

### Apple frameworks

Use:

* RealityKit for immersive rendering;
* GameController for Nintendo Switch Pro Controller input;
* Speech for on-device speech transcription;
* MapKit local search for spoken location to latitude/longitude;
* SwiftUI only for the minimal Jump To presentation and required attribution.

Do not use Google Places for Jump To. Apple’s `MKLocalSearch` already converts a natural-language place query into map items with coordinates.

## Research already completed

Treat the following as the research baseline. Read current documentation or source where exact APIs have changed, but do not repeat a broad technology survey.

Official references:

* Apple first visionOS app:
  `https://developer.apple.com/documentation/visionos/creating-your-first-visionos-app`
* Apple GameController discovery:
  `https://developer.apple.com/documentation/gamecontroller/discovering-game-controllers`
* Google Map Tiles overview:
  `https://developers.google.com/maps/documentation/tile/overview`
* Google Map Tiles policies:
  `https://developers.google.com/maps/documentation/tile/policies`
* Cesium Native rendering integration:
  `https://cesium.com/learn/cesium-native/ref-doc/rendering-3d-tiles.html`

Known visionOS proof:

* Cesium Native issue describing Google Photorealistic Tiles rendered with RealityKit on visionOS:
  `https://github.com/CesiumGS/cesium-native/issues/823`
* Published experimental visionOS application:
  `https://git.sr.ht/~netshade/traveller-share`
* Published experimental Cesium Native xrOS fork:
  `https://git.sr.ht/~netshade/cesium-native`

The existing xrOS fork’s author explicitly described it as exploratory and hacked sufficiently to build. Do not adopt it wholesale as the permanent dependency.

Start with current upstream Cesium Native. Use the experimental fork and application as implementation evidence and as a source of the smallest necessary visionOS build and RealityKit adapter ideas. Once a working Cesium revision is found, pin its commit.

### Known Cesium integration lessons

Do not rediscover these from first principles:

* Cesium Native requires platform implementations such as `IAssetAccessor`, `ITaskProcessor` and `IPrepareRendererResources`.
* Renderer resources should initially exist but remain invisible.
* After each view update, stop showing tiles that are fading out and show only the tiles requested for the current frame.
* Loaded or cached tiles are not automatically all renderable tiles.
* Geometry/index/normal work may happen during Cesium’s load-thread preparation.
* Final renderer work such as RealityKit texture creation may need to finish on the main/render thread.
* Cesium positions use global Earth coordinate systems and double precision.
* RealityKit content should use a local coordinate frame near the user.
* Use a local horizontal east/north/up frame and a floating origin.
* Heights above mean sea level/geoid and heights above the WGS84 ellipsoid are not interchangeable.
* The previous visionOS implementation solved a location-height offset with an EGM96/geoid-to-ellipsoid correction.
* Test glTF-to-RealityKit conversion with one simple known model or one isolated tile before streaming a city.
* The most useful early renderer check is a distant/global view or one static tile, not full-speed flight.

### Settled glTF-to-RealityKit renderer contract

Milestone 4 established a correct RealityKit renderer for Google Photorealistic 3D Tiles. Treat the following as settled implementation constraints, not areas for renewed experimentation:

* glTF texture coordinates use an upper-left image origin. Apply `KHR_texture_transform` in glTF texture-coordinate space first, then convert for RealityKit with `v = 1 - v`.
* Do not add another UV flip and do not flip decoded image rows.
* Honour `TextureInfo.texCoord` and any `KHR_texture_transform.texCoord` override.
* Decode texture-coordinate accessors according to their declared component type and normalisation. Preserve accessor byte offsets, buffer-view byte offsets and byte strides through Cesium's accessor views.
* Preserve the supported unsigned-byte, unsigned-short and unsigned-int index paths.
* Upload only the full-resolution base mip when Cesium stores multiple mip levels back-to-back in an image asset.
* Configure RealityKit sampler address, minification, magnification and mip-filter modes from the glTF sampler rather than relying on RealityKit defaults.
* Honour glTF `doubleSided` through RealityKit face culling.
* Preserve the existing node, model, RTC, ECEF and local-ENU transform order. Keep global calculations in double precision and convert to `Float` only for the final local RealityKit vertex payload.
* Preserve the renderer's asynchronous tile-generation guard. A tile removed while RealityKit resources are being prepared must not be installed afterward.

If later work produces a visual regression, first determine which of these established contracts was broken. Do not speculate that Google geometry, skirts, imagery or Cesium LOD is defective without new evidence that the validated importer contract still holds.

### Settled selection and LOD behavior

Cesium already performs view-dependent selection, frustum culling and screen-space-error refinement. Nearby tiles refine while distant tiles remain progressively coarser and may appear nearly flat. Broad low-detail horizon coverage is expected.

* Do not manually classify tiles by distance or implement a second LOD system.
* `maximumScreenSpaceError` controls refinement quality. `maximumSimultaneousTileLoads` limits concurrent loading, not the number of visible or cached tiles.
* Loaded or cached content is not automatically visible content. Continue showing only `tilesToRenderThisFrame` and hiding `tilesFadingOut`.
* Do not tune SSE, preload behavior, cache limits or load concurrency merely because the selected geographic area is broad. Change them only in response to measured frame time, memory pressure, loading behavior or visible LOD defects on the physical headset.

Research the current upstream APIs where names or build requirements have changed. Prefer current official Apple, Google and Cesium documentation and current upstream source.

Do not silently change the architecture after finding an inconvenience. Report the concrete blocker and the smallest proposed deviation.

## Controller interaction

The only supported controller is the **Nintendo Switch Pro Controller**.

The controller is expected to be connected before launch. No controller picker, connection UI, fallback input or disconnection recovery is required.

Use GameController’s extended gamepad profile and ensure the RealityKit/SwiftUI view receives raw controller events rather than allowing visionOS to reinterpret gamepad input as gaze-and-pinch UI interaction.

Apple’s face-button property names are positional rather than promises about the glyph printed on a Nintendo controller. The mapping below records the callbacks physically accepted with the Switch Pro Controller on the original M2 Vision Pro.

Accepted control mapping:

| Controller input            | Behaviour                      |
| --------------------------- | ------------------------------ |
| Left stick up/down          | Forward/backward translation   |
| Left stick left/right       | Strafe left/right              |
| Right stick left/right      | Yaw                            |
| Right stick up/down         | Pitch, aircraft-style inverted |
| L or R shoulder button      | Ascend                         |
| L + R shoulder buttons      | Ascend with vertical boost     |
| ZL or ZR trigger            | Descend                        |
| ZL + ZR triggers            | Descend with vertical boost    |
| GameController `buttonX`    | Roll left                      |
| GameController `buttonY`    | Roll right                     |
| Physical bottom face button (`buttonA`) | General speed boost |
| `+`                         | Open voice Jump To             |
| Right-stick click           | Reset yaw, pitch and roll      |

“Inverted pitch” means pushing the right stick physically forwards/up pitches the craft nose down; pulling it backwards/down pitches the nose up.

Treat the shoulder buttons and ZL/ZR triggers as digital buttons. Pressing either
member of a vertical pair gives normal vertical movement; pressing both members
of the same pair applies the boost multiplier to vertical movement.

Use a small dead zone. Begin with linear input. Do not create configurable curves or a settings screen.

Other unused face-button callbacks, D-pad, `-`, Home and Capture can remain unused.

## Head tracking and craft control

Head direction must never steer the craft.

The system-controlled RealityKit camera naturally follows the user’s head.

Maintain two distinct concepts:

1. **Craft pose** — controlled only by the game controller.
2. **Head pose relative to craft** — controlled only by the user’s physical head.

Moving or rotating the head changes the rendered view relative to the craft. It does not mutate the craft’s position, yaw, pitch, roll or velocity.

The combined craft-plus-head virtual camera pose may be supplied to Cesium Native for view-dependent tile selection. That is rendering input, not flight input.

Begin with one centre-eye approximation for Cesium view selection. Do not implement separate left-eye and right-eye tile-selection passes unless visible LOD artefacts demonstrate that it is necessary.

## Flight model

Use a direct kinematic flight model.

Do not use a physics engine.

Maintain:

* geographic/ECEF position in double precision;
* craft orientation as a quaternion;
* velocity or direct per-frame displacement;
* local east/north/up basis;
* elapsed frame time;
* current altitude;
* current speed multiplier.

Movement should be deterministic from controller input and frame delta.

Forward and strafe movement are relative to craft orientation.

Ascend and descend should initially follow local geodetic up/down, independent of craft roll.

Speed should scale with altitude so that:

* low-altitude movement permits controlled inspection;
* city-scale movement is fast;
* high-altitude movement can cross countries;
* the boost button multiplies the current speed.

Do not add physics-style inertia, lift, drag, gravity, collision detection, terrain avoidance, stalls or aircraft simulation. The only accepted release motion is the narrow linear left-stick and vertical release decay recorded in the Milestone 8 completion notes.

Roll is visual and directional freedom, not an aerodynamic model.

## Earth coordinate model

Keep planetary coordinates in double precision outside RealityKit.

RealityKit entities should remain near a local origin using ordinary metre-scale float transforms.

Use:

* WGS84/cartographic or ECEF for the craft’s persistent global position;
* a local east/north/up tangent frame near the current craft position;
* an Earth/content root entity transformed relative to the user;
* periodic rebasing when the local coordinate values become unnecessarily large.

Do not attempt to move RealityKit’s system camera directly. Simulate virtual travel by updating the world/content transform and the geographic craft state while the physical camera remains controlled by visionOS.

Coordinate work deserves direct comments explaining:

* source coordinate system;
* destination coordinate system;
* units;
* handedness;
* matrix multiplication order;
* whether a transform is camera-to-world or world-to-camera.

Do not conceal coordinate transforms behind generic matrix helpers with ambiguous names.

## Jump To

Pressing the physical `+` button begins one voice query.

Show only a minimal noninteractive presentation such as:

* `Jump to…`
* current recognised transcript;
* a listening indicator.

No keyboard entry, buttons, result list, confirmation, autocomplete or “did you mean” flow is required.

Pipeline:

1. Request microphone and speech permission when first required.
2. Capture one utterance with Apple Speech.
3. Put the resulting text into `MKLocalSearch.Request.naturalLanguageQuery`.
4. Take the first returned map item.
5. Read its coordinate.
6. Determine a practical ground elevation for that coordinate.
7. Convert elevation datum where required for Cesium/WGS84.
8. Place the craft approximately 1,000 metres above the ground.
9. Rebase the local world origin.
10. Resume flight.

The initial elevation source may be Google Elevation API or the simplest current equivalent already available alongside Google Maps billing. Use the minimum request and no generic elevation abstraction.

No-result behaviour may simply close the presentation and do nothing.

Unexpected programmer errors may print and return or terminate the app. Do not construct an error-presentation system.

System microphone and speech permission prompts are unavoidable and acceptable.

## Google attribution and data policy

The only persistent non-flight UI is the attribution required by Google.

Follow the current Google Map Tiles policy.

The application must show:

* the required Google Maps branding;
* the combined attribution/copyright strings associated with currently displayed tiles.

Google’s tile attribution may appear in glTF `asset.copyright`. Do not assume one static copyright string is sufficient. Aggregate and update attribution from visible content as required by the current policy.

Use Cesium Native's `CreditSystem` snapshot as the source of dynamic data attribution. It already aggregates the credits associated with the current render set. Display its unique sorted current credits in full without deliberate truncation.

Use Google's official, unmodified outlined Google Maps logo over the rendered imagery at a height within Google's required 16–19 point range. Keep the logo and current data attribution visibly associated and persistently visible. Do not replace the official asset with recreated text or artwork while the asset remains usable.

Do not build an offline city exporter or custom persistent tile archive.

A bounded transient Cesium cache needed for normal interactive streaming is acceptable. No custom long-term cache is required.

## Secrets and billing

Do not commit the Google API key.

Use one ignored file such as:

`Secrets.xcconfig`

Optionally commit:

`Secrets.example.xcconfig`

with a placeholder value.

Expose only the required build setting to the application.

Do not create:

* a backend;
* a secrets service;
* token exchange;
* proxy server;
* account system.

This is a private client app. Restrict the Google key through the controls Google currently provides, but do not pretend a key embedded in a client binary is secret.

## Suggested source shape

Keep the Swift application approximately this small:

* `EarthflightApp.swift`
* `ImmersiveView.swift`
* `FlightState.swift`
* `SwitchController.swift`
* `JumpTo.swift`
* `AttributionView.swift`
* `CesiumBridge.h`
* `CesiumBridge.mm`

Additional renderer/Cesium files are acceptable only when the C++ integration genuinely requires them.

This is a ceiling, not a request to create all files immediately.

A single Observation-compatible flight-state object is acceptable. Do not surround it with view models.

A small controller type is acceptable. Do not call it a controller manager or introduce a controller protocol.

A concrete HTTP asset accessor required by Cesium is acceptable. Do not generalise it into an application networking stack.

## Milestones

Work on one milestone at a time.

### Milestone 0 — Virgin project

* Ordinary visionOS App template.
* One target.
* Full immersive RealityKit scene.
* Builds in simulator.
* Runs on physical M2 Vision Pro.
* Clean Git commit.

### Milestone 1 — Controller diagnostic

* Direct full immersive launch.
* Simple generated grid, axes or cubes.
* Raw Switch Pro Controller events.
* Empirical physical-to-GameController mapping.
* No flight.
* No Cesium.
* No network.

### Milestone 2 — Synthetic flight rig

* Craft state and quaternion.
* Controller movement.
* Inverted pitch.
* Roll.
* Altitude-dependent speed.
* Head free-look demonstrably independent from craft steering.
* Synthetic grid/cubes only.

### Milestone 3 — Cesium Native build

* Current upstream Cesium Native built and linked for visionOS arm64.
* Smallest platform integrations required to initialise it.
* Inspect the published xrOS fork only where current upstream fails.
* Pin a known working revision.
* Validate one simple glTF or isolated tile conversion.
* No broad refactor.

After the first successful physical-device Cesium build, create or update a short tracked `BUILDING.md` recording facts rather than plans:

- exact Cesium Native commit;
- exact vcpkg commit, if used;
- Xcode version and build number;
- visionOS SDK version;
- Clang version;
- deployment target;
- selected `DEVELOPER_DIR` convention;
- complete configure and build commands;
- required CMake options;
- any local patches;
- physical-device smoke-test result.

Do not document transient failed experiments unless they explain a necessary
non-obvious workaround.

### Milestone 4 — Static Google location

* Direct Google Photorealistic 3D Tiles root.
* One static location, preferably central London/Brixton.
* Correct RealityKit mesh, texture and transform.
* Correct visible-tile selection.
* Google branding and dynamic attribution present immediately.

### Milestone 5 — Dynamic flight streaming

**Status: completed and physically accepted on the original M2 Vision Pro on 1 September 2026.**

* Per-frame Cesium view update.
* Tile appearance/disappearance.
* Camera/craft motion.
* Head-relative view included in LOD selection.
* Bounded resource use.

Milestone 5 begins from the validated Milestone 4 renderer and Cesium selection pipeline. Do not redesign the importer, texture path, material path or tile-selection machinery.

Replace the fixed Milestone 4 `ViewState` input with one centre-eye Cesium view derived from the combined craft pose and the current head pose relative to the craft. The head-relative pose affects only the rendered view and Cesium selection; it must never mutate craft orientation, velocity or flight direction.

Keep three representations coherent on every update:

1. the craft's persistent global ECEF/cartographic pose in double precision;
2. the combined craft-plus-head global view supplied to Cesium;
3. the inverse local transform applied to the RealityKit Earth/content root while the system camera remains head-controlled.

A mismatch between the Cesium selection pose and the RealityKit rendered pose causes inappropriate refinement, missing nearby detail and excessive off-screen loading. Treat pose coherence as the first diagnostic when dynamic streaming looks wrong.

Continue dispatching Cesium main-thread tasks before each view update. Preserve tile visibility semantics, asynchronous generation cancellation and current-render-set attribution while the selection changes every frame.

### Milestone 5 completion notes

Established and physically accepted on the original M2 Vision Pro on 1 September 2026:

* Dynamic Google Photorealistic 3D Tile streaming works during controller flight, with Cesium selecting and showing the current render set as the craft moves.
* The combined craft-plus-head centre-eye pose drives Cesium selection while head movement remains independent of craft position, orientation and flight direction.
* The inverse local Earth-root transform remains coherent with the Cesium view, so rendered motion, refinement and nearby detail stay aligned.
* The accepted Switch Pro flight controls, hard orientation reset, blue-gradient sky dome, visible Google branding and current dynamic attribution are all working together in the immersive experience.
* Resource use is bounded during normal dynamic streaming.

### Settled Milestone 5 flight and presentation behavior

Treat these as accepted implementation contracts. Do not redesign them during Milestone 6 merely because another representation appears more physically realistic.

* Store heading, pitch and roll as independent control state and rebuild the craft orientation basis explicitly. With roll equal to zero, yaw and pitch, including simultaneous diagonal right-stick input, must leave the horizon level. Do not restore incremental `yaw * orientation * pitch` quaternion accumulation.
* Right-stick click is a hard orientation reset. It restores the launch heading, pitch and roll while preserving geographic position and movement input state; it is not merely a roll-level command.
* The accepted background is a generated inward-facing unlit sky dome: deep blue at the zenith, softer blue through the middle and pale warm blue at the horizon. It shares the Earth-root attitude transform and remains centred on the virtual craft.
* Keep all owner-editable flight feel constants in `EarthflightTuning.swift`. The accepted curve uses a `6` horizontal speed multiplier and a two-stage vertical curve: the low-altitude curve is capped at 100 m/s, a second squared term begins above 250 m, and absolute vertical speed is capped at 3,000 m/s. Milestone 8 completion notes record the complete accepted tuning set.
* Preserve the focused transform regression test that verifies `localEarthFromCraftDelta` maps the initial craft pivot to the current craft position and that its inverse maps back. This protects the relationship between rendered RealityKit motion and the Cesium selection pose.

### Milestone 6 — Planetary coordinates

* Robust local tangent frame.
* Floating-origin rebasing.
* Reliable altitude.
* Flight across larger distances.
* Profiling and M2 device tuning only where measured.

### Milestone 6 completion notes

Established in the working Milestone 6 build:

* Craft position remains in WGS84 ECEF double precision, with a new local east/north/up render frame derived from the craft position when rebasing.
* The Earth render origin rebases after 50 km of ECEF displacement, keeping RealityKit transforms metre-scale without moving the system-controlled camera.
* Horizontal integration uses the local tangent frame in bounded 10 km steps, then reconstructs ECEF at the intended WGS84 ellipsoid height to avoid chord-induced altitude gain.
* The renderer receives the updated ECEF-to-render-local transform on each rebase, preserving the accepted craft, Earth-root and Cesium-view pose coherence across large-distance flight.
* Ellipsoid height is the authoritative flight altitude, while the existing speed reference remains explicitly separate from terrain height or AGL.

Milestone 6 must extend the accepted Milestone 5 coordinate range without breaking its Earth-root/Cesium-view pose coherence, independent head look, attitude invariants, sky presentation or transform regression test.

### Milestone 7 — Voice Jump To

* `+` input.
* Speech transcription.
* First MapKit result.
* Ground elevation.
* Geoid/ellipsoid correction.
* Teleport to 1,000 metres above ground.

### Milestone 7 completion notes

Established on the original M2 Vision Pro:

* The physical Switch Pro `+` button is `GCExtendedGamepad.buttonMenu`; only its press-down transition starts one Jump To operation.
* Jump To pauses only `FlightState.advance`; head tracking, current Cesium selection, tile lifecycle, sky, and attribution continue. A fully resolved destination crosses to the existing scene update as one pending value, where `FlightState.jump` and `googleRenderer.setRenderFrame` happen before the next Cesium view update.
* MapKit receives the exact trimmed transcript without a region and `response.mapItems.first` wins. One Google Elevation request supplies mean-sea-level ground height; bundled Cesium `WW15MGH.DAC` EGM96 supplies `N`; use `groundEllipsoidHeight = H + N`, then add the fixed 1,000 m clearance.
* The jump resets heading, pitch, and roll through the same complete orientation-reset path as a right-stick click, while preserving position at the resolved destination and active controller inputs. It centres a fresh render frame at the new ECEF craft position and sets the speed-reference ground datum, so every destination begins at a 1,000 m speed reference. It does not recreate the tileset or renderer resources.
* The preferred `SpeechAnalyzer` capture path has a concrete visionOS blocker: `AVCaptureDevice.default(for: .audio)` returned no device on hardware, and `AVCaptureDevice.DeviceType.microphone` is unavailable to visionOS. Use the single legacy `SFSpeechRecognizer` plus `AVAudioEngine` fallback, with `AVAudioNode.installAudioTap` and a copied mutable PCM buffer. Do not reintroduce both recognition paths in parallel.
* A SwiftUI `.overlay` outside a full immersive `RealityView` did not present the temporary status card on hardware. Keep Jump To status as a persistent RealityView `Attachment`, billboarded directly in front of the wearer and transparent while idle; do not replace it with an outer window overlay.
* Speech Jump To was physically exercised successfully for San Francisco, Tokyo, and Mexico City. The overlay shows the active prompt and partial transcript.

### Milestone 8 — Final feel, LOD transitions and cleanup

**Status: completed and physically accepted by the owner on the original M2 Vision Pro on 4 September 2026.**

### Milestone 8 completion notes

* Owner-editable values are centralised in `EarthflightTuning.swift`. The accepted controller and flight values are: dead zone `0.12`; yaw `1.2` rad/s; pitch `1.0` rad/s; roll `0.45` rad/s; maximum pitch `80` degrees; horizontal curve `max(3, referenceHeight * 0.3) * 6`; boost multiplier `4`; vertical curve minimum `1` m/s, low-altitude squared factor `1`, low-altitude cap `100` m/s, high-altitude threshold `250` m, high-altitude excess-squared factor `0.0015`, and absolute cap `3,000` m/s.
* Left-stick translation and vertical movement have a linear `0.5` second release decay. Active input remains immediate. Setting the duration to zero disables the effect and bypasses its state and calculations. Any new deliberate input cancels the existing decay. Per-axis release state preserves the strongest deliberate sample so the Switch Pro stick's opposite-direction recenter rebound cannot reverse a same-direction release tail.
* The accepted controller remap is: `buttonX` rolls left; `buttonY` rolls right; either L or R ascends; either ZL or ZR descends; holding both ascent buttons or both descent buttons applies the normal `4` times boost to vertical movement. The physical bottom face button remains the general boost control. Right-stick click remains the complete orientation reset.
* A completed Jump To now performs that same complete orientation reset. It preserves the resolved destination position and active controller input, while clearing any residual movement-release tail.
* Cesium LOD selection uses maximum screen-space error `24`, maximum simultaneous tile loads `8`, and LOD transitions enabled with a `0.3` second transition length. No custom distance LOD, fog-density tuning, tile excluder, fade shader, or second selection system was added.
* The Cesium transient in-memory tile cache is `1 GiB` (`1,024 * 1,024 * 1,024` bytes). It is not a persistent disk cache. The larger bound may reduce reloads after looking away and back, at the cost of additional memory pressure.
* RealityKit's transparent `OpacityComponent` crossfade was rejected because overlapping photogrammetry exposed the sky and geometry behind tall structures. The accepted transition is an opaque, readiness-gated handoff: Cesium transition progress pauses while any selected replacement is still awaiting guarded RealityKit installation; the replacement reports ready only after its tile container is attached to `earthRoot`; outgoing tiles remain enabled and fully opaque until Cesium says the transition has completed, and only then use the existing hide path. This contract applies in both refinement and unrefinement directions.
* Tile containers remain identity children of `earthRoot`, while primitive transforms retain their independent ECEF/render-local anchors. Generation-token checks prevent freed or hidden tiles from reappearing after asynchronous preparation, and installation uses the latest render frame so rebases and Jump To remain coherent.
* Milestone 6/7 planetary telemetry, its attachment and periodic console summary were removed. Sanitised failure diagnostics and the Jump To attachment remain.
* Google attribution remains a persistent screen-space overlay and is shifted left with a `220` point trailing inset.
* The procedural inward-facing unlit sky remains deliberately simple. Its radius is `600,000` metres; the accepted upper blue gradient remains, while the lower hemisphere now fades to a light dull sandy brown so a brief terrain gap is less stark than the former uninterrupted horizon blue.

Do not start a later milestone merely because the current change makes it convenient.

## Codex working rules

Before editing:

1. Read this file.
2. Inspect the current repository.
3. Identify the current milestone.
4. Preserve all settled decisions.
5. State any concrete blocker before changing architecture.

During editing:

* Make the smallest coherent change.
* Keep unrelated formatting and project-setting churn out of the diff.
* Do not add tests unless requested. When requested, prefer one focused regression test in the existing target.
* Do not delete tests that already exist.
* Do not add dependencies without explaining why the current milestone cannot proceed without them.
* Do not introduce abstractions in preparation for later milestones.
* Build after meaningful changes.
* Use current official documentation when an API name, entitlement, capability or visionOS build requirement is uncertain.
* Inspect current upstream source when Cesium documentation is insufficient.
* Prefer evidence from the actual compiler and actual M2 headset over speculation.

After editing, report:

* files changed;
* project/build settings changed;
* build destination used;
* whether the build succeeded;
* warnings that matter;
* exact manual checks to perform on the physical Vision Pro;
* anything that could not be verified without the hardware.

When physical-headset validation is required, state plainly that the agent's
device-interaction service does not support visionOS hardware and provide the
owner with the exact manual checks instead of investigating alternative
screenshot or hierarchy mechanisms.

Never claim that controller mapping, comfort, visual correctness or device performance has been verified unless it was actually checked on the physical headset.

Do not create Git commits unless explicitly asked.

Each milestone will be executed by a different LLM coding session, so liberally include comments in the code that will materially benefit future sessions if knowledge should be passed forwards.

When two implementations are viable, choose the simpler reversible one. Do not future-proof.
