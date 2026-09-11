# MILESTONES.md — Earthflight

The order the app was built in, one line each. All of these are done and were
accepted on the original M2 Apple Vision Pro. They are here so a new session can
see the shape of the thing quickly, not as work to redo.

| # | Milestone | What it delivered |
|---|---|---|
| 0 | Virgin project | One visionOS target, one full immersive RealityKit scene, running on the headset |
| 1 | Controller diagnostic | Raw Switch Pro Controller events, and the empirical physical-to-GameController mapping |
| 2 | Synthetic flight rig | Craft pose, inverted pitch, roll, altitude-scaled speed, head look proven independent of steering — over generated geometry |
| 3 | Cesium Native build | Upstream Cesium Native built and linked for visionOS arm64, at a pinned commit, with one glTF conversion validated |
| 4 | Static Google location | Google's tileset over central London with correct meshes, textures, transforms, visible-tile selection and attribution |
| 5 | Dynamic flight streaming | Per-frame Cesium view updates during flight, with craft, view and render poses kept coherent |
| 6 | Planetary coordinates | Double-precision ECEF, floating-origin rebasing, reliable ellipsoid height, flight across the whole planet |
| 7 | Voice Jump To | `+`, one spoken utterance, first MapKit result, ground elevation with geoid correction, arrive 1,000 m up |
| 8 | Final feel and LOD transitions | The accepted controller feel and release decay, and an opaque readiness-gated tile handoff with no flashing |
| 9 | Additions beyond the brief | An air-mass sky gradient, a star field, a head-up display, and the move to Swift 6 language mode |
| 10 | Giant mode | The D-pad scales the wearer in doublings, so binocular depth reads at city distances rather than only up against a building |

## Where it stands

The app does what it set out to do and the owner is happy with it. The value now
lives in the code; these documents exist to keep a future session from breaking
it or re-deriving it.

## Known limitation

In steep mountainous terrain a thin sliver of sky can show along a boundary
between two adjacent tiles at different levels of detail. It is a geometric seam,
not a texture or readiness problem, and it is low priority. GOTCHAS.md explains
what it is not, and how to look at it without reviving something that was already
rejected.

## Possible next things, if the owner asks

* Fade the horizon bar out with altitude, the way the sky and stars already fade
  with air mass. Local horizontal stays well defined at any height, but at
  1,000 km the true horizon is 30 degrees below the bar and the mark means less.
  `StarField.visibility` is the pattern to copy.
* 3Dconnexion SpaceMouse support — a proper six-axis controller for a
  six-degree-of-freedom world. This is a long-standing wish, not a plan.

Do not start any of these because the change in hand makes it convenient.
