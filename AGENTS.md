
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
10. Nothing else is added.

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

### Explicitly prohibited unless the owner later asks for them (some tests will certainly be requested from time to time)

Do not create:

* unit tests;
* UI tests;
* Swift Testing or XCTest targets;
* test fixtures;
* mocks;
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

Research the current upstream APIs where names or build requirements have changed. Prefer current official Apple, Google and Cesium documentation and current upstream source.

Do not silently change the architecture after finding an inconvenience. Report the concrete blocker and the smallest proposed deviation.

## Controller interaction

The only supported controller is the **Nintendo Switch Pro Controller**.

The controller is expected to be connected before launch. No controller picker, connection UI, fallback input or disconnection recovery is required.

Use GameController’s extended gamepad profile and ensure the RealityKit/SwiftUI view receives raw controller events rather than allowing visionOS to reinterpret gamepad input as gaze-and-pinch UI interaction.

Apple’s face-button property names are positional rather than promises about the glyph printed on a Nintendo controller. The first controller milestone must empirically map every physical control on the real Vision Pro before flight controls are finalised.

Target physical controls:

| Physical Switch Pro control | Behaviour                      |
| --------------------------- | ------------------------------ |
| Left stick up/down          | Forward/backward translation   |
| Left stick left/right       | Strafe left/right              |
| Right stick left/right      | Yaw                            |
| Right stick up/down         | Pitch, aircraft-style inverted |
| ZR                          | Ascend                         |
| ZL                          | Descend                        |
| R                           | Roll right                     |
| L                           | Roll left                      |
| Physical bottom face button | Speed boost                    |
| `+`                         | Open voice Jump To             |
| Right-stick click           | Optional: level roll/horizon   |

“Inverted pitch” means pushing the right stick physically forwards/up pitches the craft nose down; pulling it backwards/down pitches the nose up.

Treat ZL and ZR as digital buttons. No analogue-trigger model is needed.

Use a small dead zone. Begin with linear input. Do not create configurable curves or a settings screen.

Other face buttons, D-pad, `-`, Home and Capture can remain unused.

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

Do not add inertia, lift, drag, gravity, collision detection, terrain avoidance, stalls or aircraft simulation during the initial implementation.

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

### Milestone 4 — Static Google location

* Direct Google Photorealistic 3D Tiles root.
* One static location, preferably central London/Brixton.
* Correct RealityKit mesh, texture and transform.
* Correct visible-tile selection.
* Google branding and dynamic attribution present immediately.

### Milestone 5 — Dynamic flight streaming

* Per-frame Cesium view update.
* Tile appearance/disappearance.
* Camera/craft motion.
* Head-relative view included in LOD selection.
* Bounded resource use.

### Milestone 6 — Planetary coordinates

* Robust local tangent frame.
* Floating-origin rebasing.
* Reliable altitude.
* Flight across larger distances.
* Profiling and M2 device tuning only where measured.

### Milestone 7 — Voice Jump To

* `+` input.
* Speech transcription.
* First MapKit result.
* Ground elevation.
* Geoid/ellipsoid correction.
* Teleport to 1,000 metres above ground.

### Milestone 8 — Feel

* Tune dead zones.
* Tune pitch/yaw/roll rates.
* Tune altitude-speed curve.
* Tune boost.
* Remove leftover diagnostics.
* Preserve the minimal application.

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
* Do not add tests unless requested
- Do not delete tests that already exist
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

Never claim that controller mapping, comfort, visual correctness or device performance has been verified unless it was actually checked on the physical headset.

Do not create Git commits unless explicitly asked.

Each milestone will be executed by a different LLM coding session, so liberally include comments in the code that will materially benefit future sessions if knowledge should be passed forwards.

When two implementations are viable, choose the simpler reversible one. Do not future-proof.
