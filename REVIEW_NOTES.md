# GreenSight stability and performance review

## Release

- Version: 1.1 (build 2)
- Review date: 23 November 2026
- Deployment target: iOS 17
- Project language mode: Swift 5 with complete strict-concurrency diagnostics enabled

## Correctness and stability fixes

- Bounded scene-depth processing to one in-flight frame. New camera frames are dropped while projection/fusion is busy instead of accumulating an unbounded queue.
- Added scan-generation IDs to depth fusion, snapshots and trajectory completion. Work from a restarted or undone scan cannot mutate the current scan.
- Serialized the final snapshot after any in-flight depth frame, then performs trajectory analysis off the main thread.
- Moved demo generation, history loading, JSON saves and export generation off the main thread.
- Added native-image-to-viewport transforms for automatic landmark suggestions, including RealityKit viewport rotation and crop.
- Validated depth-buffer format, dimensions and lock results before direct pixel-buffer access.
- Added lifecycle pause/resume handling for the AR session.
- Reused and explicitly replaced the RealityKit root anchor rather than leaking an anchor on each restart.
- Enabled horizontal plane detection and prefer existing plane geometry for landmark raycasts.
- Added a regression test proving that late frames from an old scan are rejected.

## Performance fixes

- Precomputed per-cell surface gradients once when creating `GreenSurface`; the trajectory optimiser no longer estimates each gradient with repeated height lookups.
- Added a direct O(1) cell-gradient path for heatmap drawing.
- Replaced each cell's `removeFirst()` history maintenance with a fixed-size circular replacement strategy.
- Throttled live surface snapshot publication to at most once per 0.75 seconds while retaining accepted depth observations.
- Kept Vision contour processing and trajectory optimisation on dedicated queues and persistence on a utility queue.
- Rejected candidate putts that leave measured surface support and reduced confidence when the final path is unsupported.

## Validation completed in this environment

- ZIP input integrity and SHA-256 verified before review.
- Deterministic Xcode project regenerated successfully.
- All project references resolve.
- Plist, asset-catalog and project-structure checks pass.
- Platform-neutral geometry and physics checks pass.
- Python validation scripts compile.
- Swift delimiter structure check passes.

## Validation still required on macOS and hardware

This Linux environment does not include Xcode, the Swift compiler or Apple SDKs. Before treating this build as complete, run the XCTest suite and a Release build in current Xcode, then profile on a LiDAR-equipped iPhone using Instruments. Validate depth accuracy on a surveyed level surface before relying on putting guidance.
