# FIXES LOG — BlackholeSimulator

## 2026-05-26: Opaque center + zoom range

### Problem 1: Transparent event horizon center
Stars were bleeding into the black hole shadow because the starfield_lens pass added stars wherever HDR luminance was < 0.05. The event horizon pixels have `lum=0.0` like escaped empty-space rays, so the luminance threshold alone couldn't tell them apart.

### Solution 1: Angular shadow mask (Starfield.metal)
Added an angular shadow mask using the photon-sphere critical impact parameter:
- `b_crit = rs * sqrt(27) / (2 * |ro|)` — angular radius of the BH shadow on screen
- Compute each camera ray's impact parameter: `impact = |cross(ro, rd)| / |ro|`
- If `impact < shadow_angular_radius`, suppress star blending with smoothstep transition
- Added 5% margin for higher-order photon rings

Before: stars everywhere dark, including BH center
After: stars only outside the actual gravitational shadow

### Problem 2: Zoom too limited
Camera zoom range was [3, 80] with scroll multiplier 0.5 — couldn't scroll out far enough to see full disk structure.

### Solution 2: Extended zoom (Camera.swift)
Changed: `max(3, min(80, distance - delta * 0.5))` to `max(2, min(250, distance - delta * 1.5))`
- Min zoom: 3 -> 2 (closer to BH)
- Max zoom: 80 -> 250 (3x farther)
- Speed: 0.5 -> 1.5x (3x faster response)

### Files changed:
- BlackholeSimulator/Shaders/Starfield.metal — added angular shadow mask (lines 57-71)
- BlackholeSimulator/Sources/Camera.swift — zoom range and speed (line 29)

### Build status:
Clean build, no new warnings. App running stable with no crashes.
