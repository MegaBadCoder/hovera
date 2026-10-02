# Optional AprilTag camera tracking
Goal: user can select AprilTag instead of face/glasses tracking and use printed tag36h11 IDs 0–2 for camera-relative screen anchoring. Live accuracy requires the user's mounted prints.
Worktree: /Users/v/projects/hovera/.worktrees/camera-glasses; branch: camera-glasses.

## Context
- CameraHeadTracker owns camera capture, history-aligned IMU samples, translation and yaw corrections.
- Printed tags use 15/20/25/30 mm outer black squares; ID0 front, ID1 left, ID2 right.
- Existing face/glasses mode must remain available and the default.

## Design
Vendor pinned AprilTag C detector behind a narrow bridge. Separate Swift detection and rigid-tag geometry from the app. Use camera intrinsic metadata if available, otherwise a manually adjustable FOV estimate (70° default), explicitly labelled. macOS does not expose the device FOV or intrinsic-delivery toggle used on iOS. Calibrate ID0 while stationary; learn side-tag transforms only during stable simultaneous observations. Keep known transforms fixed until reset. Never use an unknown ID as an independent reference. Missing or stale frames hold translation and apply no new yaw correction. Provide menu selection, print size, reset and live status in camera preview.
TDD: yes for rigid transforms and detection; UI tested by build/manual inspection.

### Invariants
- IV1 — Face/glasses mode is preserved; mode/size/reset invalidates AprilTag reference and cached frames.
- IV2 — Only tag36h11 IDs 0–2, nonduplicate IDs and qualified fresh poses can influence tracking.
- IV3 — Side tags require calibrated relative transforms; switching tags preserves the root frame.
- IV4 — Camera corrections preserve the visual reference; manual world rotation transforms that reference.
- IV5 — No face fallback or correction from absent tags.

### Assumptions and unknowns
- AS1 — ID0 is rigidly mounted upright on the front of the glasses, approximately aligned with the glasses; camera remains stationary.
- UK1 — Print quality, lens distortion and pose jitter require live testing; no claim of solved drift.

## Plan
Single sequential phase, no separate commit requested: C bridge and synthetic detector tests; AprilTagRig with synthetic rigid-pose tests; capture adapter and mode/settings/menu wiring; full tests, release build, manual preview, install with backup.
Files: Package.swift; Sources/CAprilTag/* (create); Sources/AprilTagTracking/* (create); Tests/RayDeskCoreTests/AprilTagTests.swift (create); CameraHeadTracker.swift captureOutput/reset/reference/reading; AppDelegate.swift menus/mode/headOffset; build.sh source fingerprint.
Interfaces: AprilTagDetector.detect(gray:width:height:intrinsics:size:) -> [TagObservation]; AprilTagRig.update(observations:time:head:speed:) -> Reading?; reset(), rotateWorld(by:).
Rollback: return to original mode via menu; preserve previous app bundle. Dependencies are vendored with source revision and license. Work stays uncommitted to preserve existing edits.
Authorization: user explicitly requested implementation as a second mode; routine design approval is already covered by that request under session instructions.

## Verification and delivery
- RED: rigid geometry, native detection and anchor tests failed against initial stubs; GREEN: implementations pass.
- Full suite: 274 tests passed; includes eight AprilTag tests and a perspective-rendered tilted-marker pose test. `git diff --check` passed.
- Independent review found that manual recenter reset AprilTag calibration through the preserved glasses preference. Both recenter paths now skip that face/glasses reset while AprilTag is active.
- Release build succeeded; installed build d1357f1f94e4 at /Applications/RayDesk.app.
- Previous bundle: /private/tmp/RayDesk-before-apriltag-20261001-200227.app.
- Manual launch reached the existing “Очки не найдены среди дисплеев” alert. RayNeo is not available as a display, so live menu/camera/physical-print checks remain unverified. No AprilTag preference was enabled during delivery.
- User guide: docs/apriltag.md. Camera FOV is an explicit estimate on macOS unless frame metadata is available; live accuracy is not established.

## Live failure and diagnostic containment
Live log at 20:07:55 showed -21.302 degrees correction in one reporting interval. Shared corrector increases still correction rate with error without an absolute ceiling; optical error source remains unproven. Disabled AprilTag preference and restarted to glasses mode. New diagnostic-only mode removes optical yaw correction calls, returns zero optical renderer translation, does not own compass heading, and does not enable wallMode. Per-frame APRIL_DIAG stores numeric pose/IMU comparison without images. Full 274-test suite passed. Physical jump reproduction with these measurements remains pending.
