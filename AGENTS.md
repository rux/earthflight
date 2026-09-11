# AGENTS.md — Earthflight

## What this is

A private visionOS app for one original M2 Apple Vision Pro, one Nintendo Switch
Pro Controller and one owner who runs and repairs it from Xcode. You fly a
virtual craft through Google's Photorealistic 3D Tiles with a gamepad while your
head independently controls where you look.

It is a personal instrument, not a product, an SDK or an architecture exercise.
It is a hobby project, not a mathematical proof.

## The other three files

* /**docs/GOTCHAS.md** — hard-won knowledge, by subsystem. Read the relevant section
  before touching tiles, textures, coordinates, sky, stars, the HUD, Jump To or
  any Objective-C callback. It exists so you do not repeat an investigation that
  has already been paid for once.
* **/**docs/MILESTONES.md** — what was built, in order, and what is left.
* **/**docs/BUILDING.md** — the known-good native build of Cesium Native: pinned commits,
  toolchain identity, exact commands. Facts, not plans. Load-bearing; change it
  only when the facts change.
READ THESE before making any changes.

## How this project likes to be treated

Take the shortest understandable path to a satisfying result on this one device.

Prefer direct code, a few small concrete types, ordinary functions, local state,
`print`, `assert`/`precondition`/`fatalError`, and force unwraps where the
project's fixed assumptions make them honest. Crash, fix the defect, relaunch:
that is an acceptable workflow here.

Be ruthless about product complexity and careful about systems correctness. The
things that genuinely need care are C++/Swift ownership, threading and actor
isolation, RealityKit entity and resource lifetime, tile visibility, coordinate
transforms, floating-point precision, floating-origin rebasing, Google
attribution, and keeping memory bounded.

### Do not build

No dependency injection, invented protocols, factories, repositories,
coordinators, service locators, view models, MVVM, TCA or Clean Architecture. No
generic networking, caching or persistence layers. No CI, analytics, telemetry,
feature flags or remote configuration. No onboarding, tutorials, settings
screens, error-presentation systems, retry frameworks or diagnostics dashboards.
No localisation, multiple profiles, multiple controllers, keyboard or
hand-tracking input, or custom gestures. No game mechanics, scores, points of
interest, labels or multiplayer. No reusable framework or SDK extraction. No
speculative abstraction and no future-proofing.

No third-party Swift packages beyond what Cesium Native genuinely needs in order
to compile.

Do not add a folder hierarchy to classify a dozen files, and do not create empty
types or files ahead of the work that needs them.

### Tests are opt-in

`earthflightTests` holds 29 focused regression tests and they earn their place:
they pin flight invariants, transform round-trips, texture orientation, sky and
star maths and HUD geometry that would otherwise need the headset to check.

Do not add tests unless asked. When asked, add the smallest focused test to that
existing target — no second target, no fixtures, no mocking framework. Never
delete a test that already exists.

### Tuning belongs to the owner

Every owner-editable feel and presentation value lives in
`EarthflightTuning.swift`, documented in place. That is where tweaking happens.
There is no settings UI and there will not be one.

Put new tunable constants there, with their units and a one-line reason. Do not
scatter them back into the code that uses them, do not rename them unasked, and
never change an accepted value as a side effect of another change. If your
change needs different tuning, say so and let the owner decide.

## Invariants

* Head direction never steers the craft. The controller owns craft pose; the head
  owns the view. The combined pose feeds Cesium's tile selection, which is
  rendering input, not flight input.
* The craft's position is WGS84 ECEF in double precision. RealityKit only ever
  sees a metre-scale local frame, which rebases as the craft travels.
* The system camera is never moved. `earthRoot` moves instead.
* No physics engine, inertia, lift, drag, gravity, collision or stall. Flight is
  direct kinematics from controller input and frame time.
* Google's branding and the credits for currently visible tiles are always on
  screen.
* One Cesium selection pipeline. Never a second LOD system.

## The stack, settled

Swift, SwiftUI, one `ImmersiveSpace`, full immersion, `RealityView`, RealityKit,
exactly one app target. Swift 6 language mode with `SWIFT_STRICT_CONCURRENCY =
complete`, `SWIFT_APPROACHABLE_CONCURRENCY = YES` and
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

Earth data is Google Map Tiles Photorealistic 3D Tiles, straight from Google's
root tileset. Cesium Native does traversal, view-dependent selection, LOD,
culling, loading, glTF parsing and cache eviction, but draws nothing; a small
Objective-C++ bridge hands its decoded glTF to Swift as plain payloads, and
RealityKit meshes, textures and materials are built from those.

GameController for input, Speech for on-device transcription, MapKit local search
for spoken places, SwiftUI only for Jump To and attribution.

Deliberately not used: Unity, a custom Metal renderer, Cesium Ion, a separate
framework target, Google Places, Apple Flyover or any reverse-engineered map
data, offline mesh exports. The physical device is the only supported
destination: the simulator does not link, and simulator support is not wanted.

Reopen any of this only with a concrete build, API or measured performance
blocker — and state the blocker before changing course.

## Where things live

| File | What it holds |
|---|---|
| `earthflightApp.swift` | Entry point; launches straight into the immersive space |
| `ImmersiveView.swift` | The `RealityView`, the per-frame scene update, and how everything is wired together |
| `FlightState.swift` | Craft pose in double-precision ECEF, controller integration, floating-origin rebasing |
| `SwitchController.swift` | GameController binding and current input state |
| `EarthflightTuning.swift` | Every owner-editable constant |
| `GoogleTileRenderer.swift` | Cesium's selected tiles as RealityKit entities: preparation, publication, retirement, render frame |
| `CesiumBridge.h` / `.mm` | The Objective-C++ boundary: hosts the Cesium tileset and decodes glTF into flat primitive payloads |
| `HeadTracking.swift` | Head pose relative to the craft |
| `SkyDome.swift` | The air-mass sky gradient and its dome |
| `StarField.swift` | Stars, faded in by air mass |
| `HeadUpDisplay.swift` | The nose ring and horizon bar |
| `GiantMode.swift` | How large the wearer is, and therefore how small the world is |
| `JumpTo.swift` | The `+` voice teleport: speech, MapKit, elevation, geoid correction |
| `GoogleAttributionView.swift` | Required Google branding and current credits |
| `earthflightTests/` | The regression tests |
| `scripts/` | Native Cesium build, and the toolchain-identity check that runs as a build phase |

## Controller mapping

Apple's face-button property names are positional and promise nothing about the
glyph printed on a Nintendo controller. This table records what the hardware
actually does. Verify any new button on the headset rather than inferring it.

| Input | Behaviour |
|---|---|
| Left stick up/down | Forward/backward |
| Left stick left/right | Strafe |
| Right stick left/right | Yaw |
| Right stick up/down | Pitch, aircraft-style inverted |
| Right-stick click | Full orientation reset to the launch attitude |
| L or R | Ascend; both together adds the vertical boost |
| ZL or ZR | Descend; both together adds the vertical boost |
| `X` / `Y` | Roll left / roll right |
| Bottom face button (`buttonA`) | General speed boost |
| `+` (`buttonMenu`) | Open voice Jump To |
| `-` (`buttonOptions`) | Toggle the head-up display |
| D-pad up / down | Grow / shrink the wearer; see giant mode below |

Inverted pitch means pushing the right stick physically forward pitches the nose
down. The D-pad's left and right, Home and Capture are unused.

## Toolchain transitions

After Xcode or the visionOS SDK changes:

1. do not reuse Cesium Native, vcpkg or other native binaries built by the
   previous toolchain;
2. confirm `DEVELOPER_DIR` selects a full Xcode, not
   `/Library/Developer/CommandLineTools`;
3. rebuild the pinned native dependencies from source;
4. rebuild the app;
5. repeat a headset smoke test before starting anything new;
6. update BUILDING.md's known-good record.

Do not add compatibility layers for superseded toolchains; support the installed
one. A device OS update on its own is not a toolchain transition. Neither is a
Swift language-mode change — but that still needs its own headset smoke test,
because it can alter runtime behaviour without changing a line of Swift.

## Building and testing

`xcode-select` on this machine points at the Command Line Tools, so every build
needs `DEVELOPER_DIR` set explicitly:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

xcodebuild build -project earthflight.xcodeproj -scheme earthflight \
  -configuration Debug -destination 'generic/platform=visionOS'

xcodebuild test -project earthflight.xcodeproj -scheme earthflight \
  -configuration Debug -destination 'platform=visionOS,id=00008112-000264992221A01E'
```

Build both Debug and Release for `generic/platform=visionOS` after meaningful
changes. Tests run in Debug on the paired headset (`RuxVision`) and take two to
four minutes, mostly install time. The simulator cannot link, and
`build-for-testing` in Release has never worked because `ENABLE_TESTABILITY` is
off there — do not chase either. BUILDING.md covers the native build.

## Secrets

The Google API key lives in the ignored `Secrets.xcconfig`;
`Secrets.example.xcconfig` carries a placeholder. Expose only the one build
setting the app needs. No backend, proxy, token exchange or account system. A key
inside a client binary is not secret; restrict it with Google's own controls
instead of pretending otherwise.

## The headset is the only judge

The agent's device-interaction service does not support visionOS hardware. That
is a known tooling limitation, not a signing, pairing or project fault. Do not
probe it repeatedly, do not hunt for an alternative screenshot or accessibility
route, and do not adjust the project because that service refuses the headset.

So never claim that controller feel, immersive placement, visual correctness, LOD
behaviour, attribution position, comfort or performance has been verified. Build,
then hand the owner a short numbered list of manual checks. The owner is the
authoritative observer for everything visible or felt.

## Working rules

Before editing, read this file and the relevant part of GOTCHAS.md, look at the
current code, and preserve the settled decisions.

While editing: make the smallest coherent change; keep unrelated formatting and
project-setting churn out of the diff; when two designs are viable, take the
simpler reversible one; consult current Apple, Google and Cesium documentation,
or upstream source, when an API is uncertain. The installed SDK and compiler are
authoritative — your knowledge cut-off is earlier than they are, so do not
"correct" current code to match a remembered older API.

Leave comments that explain why: coordinate systems, units, handedness,
multiplication order, and platform behaviour you had to discover. A future
session has no other way to learn them.

After editing, report the files changed, any build settings changed, the
destination used, whether the build succeeded, warnings that matter, the manual
headset checks the owner should run, and anything you could not verify. Do not
create Git commits unless asked.
