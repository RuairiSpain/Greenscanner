# GreenSight

GreenSight is an original iPhone AR putting-green reader implemented in SwiftUI, ARKit, RealityKit and Vision. It contains no GreenScanner, ProSide or OnePutt source code, assets, branding or reverse-engineered private interfaces.

## Included feature set

- LiDAR scene-depth capture with ARKit gravity-aligned world tracking.
- Automatic contour-based ball/cup suggestions plus manual tap fallback.
- Correctly scaled camera intrinsics and camera-to-world depth unprojection.
- Low-confidence, out-of-range and non-normal-tracking rejection.
- Bounded frame processing that drops excess camera frames instead of building a latency and memory backlog.
- Scan-generation guards that prevent late frames or calculations from contaminating a restarted scan.
- Gravity-aligned 30 mm height map over the ball-to-cup corridor.
- Robust per-frame cell estimates, MAD outlier rejection and capped frame influence.
- Surface interpolation, local slope estimation, heatmap and elevation-band view.
- Deterministic rolling-sphere simulator with adjustable Stimpmeter speed.
- Three-pass line/speed optimisation with cup-entry and arrival-speed checks.
- RealityKit trajectory, start-line, ball and cup overlays.
- Coverage and confidence indicators, diagnostic overlay and guided workflow.
- On-device scan history and JSON export; no photo/video persistence or backend.
- Background trajectory analysis and persistence so demo generation and JSON writes do not block the UI.
- Demo surface for UI and physics testing without LiDAR.
- XCTest coverage for coordinate basis, slope recovery and trajectory behaviour.

## Requirements

- macOS with Xcode 16 or newer recommended.
- iOS 17 or newer.
- A physical iPhone that reports `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)` for live scanning. In practice, use a LiDAR-equipped Pro model.
- An Apple ID added to Xcode. A free Personal Team is sufficient for local device testing; paid membership is required for wider distribution.

## Install on your iPhone

1. Copy or unzip this folder onto a Mac.
2. Open `GreenSight.xcodeproj` in Xcode.
3. Select the **GreenSight** project, then the **GreenSight** target.
4. Under **Signing & Capabilities**, select your Team.
5. Change the bundle identifier from `com.example.GreenSight` to a unique value, for example `com.yourname.GreenSight`.
6. Connect the iPhone by cable or pair it with Xcode over Wi-Fi.
7. Unlock the iPhone and enable **Developer Mode** if iOS requests it.
8. Select the iPhone as the run destination and press **Run** (`⌘R`).
9. Accept the camera permission prompt.

No pre-signed IPA is included: an installable iOS binary must be signed with your Apple team and device provisioning profile. Xcode performs that signing when you follow the steps above.

## First test

1. Set the estimated green speed under **Settings**.
2. Tap **Start green scan**.
3. Aim at the ball. Let the contour suggestion select it or tap the ball centre.
4. Aim at the cup and do the same.
5. Sweep slowly from side to side over the entire corridor. Keep the phone roughly 0.5–1.5 m above the turf and avoid fast rotation.
6. Continue until coverage is useful, then tap **Calculate**.
7. Inspect the AR line, starting speed, aim offset, confidence and slope map.
8. Use **Export** to share the latest reconstructed surface and result as JSON.

Use **Run demo without LiDAR** to exercise the heatmap, physics, result UI and export flow on unsupported hardware.

## Architecture

```text
GreenSight/
├── AppModel.swift             workflow, ARSession delegate, processing orchestration
├── DepthProjector.swift       depth/confidence readout and intrinsics-aware unprojection
├── LandmarkDetector.swift     Vision contour suggestions
├── HeightMap.swift            per-frame fusion, robust cells and surface interpolation
├── PuttingPhysics.swift       rolling model and line/speed optimiser
├── ARRenderer.swift           RealityKit markers and trajectory
├── ARScreen.swift             guided live-scanning UI
├── HeatMapView.swift          slope/elevation visualisation
├── HistoryView.swift          local completed-read history
├── SettingsView.swift         Stimp, capture and diagnostics controls
├── ScanStore.swift            local JSON persistence/export
└── DemoFactory.swift          deterministic synthetic green
```

### Coordinate conventions

- ARKit world alignment is `.gravity`; world Y is elevation.
- Depth is read from the raw `sceneDepth` map, not temporally smoothed depth.
- Camera intrinsics are scaled from camera-image resolution to depth-map resolution.
- Camera points use negative Z in front of the camera, then `ARCamera.transform` maps them to world space.
- The local surface basis has X across the putt, Y from ball to cup and height relative to the ball.
- The implementation does not flatten the fitted green; genuine uphill/downhill grade is retained.
- Live surface publication is throttled while every accepted depth frame still contributes to fusion.

### Physics model

Horizontal acceleration is approximated as:

```text
a = -(5/7) g ∇h - a_roll v̂
```

`a_roll` is derived from the selected Stimpmeter distance using a 6 ft/s reference release speed. The optimiser searches launch angle and speed at successively finer resolution. This is a deterministic engineering model, not a trained trajectory predictor.

## Validation

On a Mac with Xcode, run:

```bash
xcodebuild \
  -project GreenSight.xcodeproj \
  -scheme GreenSight \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  test
```

The AR scan itself requires a physical scene-depth device. The repository also includes platform-neutral checks:

```bash
python3 Scripts/reference_validation.py
python3 Scripts/validate_project.py
```

If source files are added, regenerate the deterministic Xcode project:

```bash
python3 Scripts/generate_xcodeproj.py
```

## Measurement and rules limitations

This is an engineering test build, not a validated surveying instrument or guaranteed putting aid. iPhone LiDAR, AR pose drift, turf reflectance, scan motion, occlusion and the assumed green speed can all affect the result. Validate against surveyed test surfaces and controlled ball rolls before treating it as accurate.

Use during a round may be restricted by the Rules of Golf, a Model Local Rule or the competition committee. Verify the applicable rules before use.

## Apple references

- ARKit scene depth: https://developer.apple.com/documentation/arkit/arframe/scenedepth
- Point-cloud sample: https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth
- Camera intrinsics: https://developer.apple.com/documentation/arkit/arcamera/intrinsics
- Running on a physical device: https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices

## License

MIT. See `LICENSE`.

## Map a Green mode (v1.3, work in progress)

A separate tab for scanning a whole green so its slopes can be shared later. Flow: choose course and hole, mark the green edge (tap, "Add point", or auto-drop every 2 m), close the shape, then walk the inside while the AR overlay and minimap show scanned (green) and too-far (amber) areas. Reads are saved locally per green and can be exported or imported as `.greensight.json` files. Upload and merging of several users' scans are not implemented yet.

### Merging scans (v1.4)

When a course has two or more scans of the same hole, the Map tab offers "Merge n scans". The best-quality scan is the reference. Every other scan is aligned to it by overlaying the green outlines (rotation limited to about 25 degrees when both scans are north-aligned, a full search otherwise), then its heights are corrected for a constant offset and, when well constrained, a small tilt, using the area both scans cover. Cells are combined by quality, observation count and range weighting, with disagreeing outliers rejected. The merged outline is the union of the aligned outlines. A scan that does not match is skipped and the reason is shown before you save.
