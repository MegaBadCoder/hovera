# Face-based centre holding
Goal: centre stays steady using the built-in face estimate and IMU; manual R establishes a new world alignment. Physical wearing validation remains required.

## Context
User prioritises centre stability, with manual R for alignment. Existing Vision face path measures translation but never calls yaw correction; glasses/CoreML correction depends on learned shape. AprilTag remains diagnostic-only. Recorded gyro integration diverged from repeat visual poses; camera must not learn that error as its own scale.

## Design
Use existing Vision face yaw/pitch with one face, sufficient confidence, unclipped frame and fresh timestamp. Learn the initial relation between IMU yaw and face yaw during one steady second. Correct only persistent small discrepancies near the reference face pose, with smoothing, a deadband and a fixed maximum rate. Suspend on face loss, fast turns, outliers or >8° discrepancy; report R needed for large error. R resets the face reference, rejecting in-flight frames. Face-centre mode outputs no camera translation or eye-arc offset. Original glasses mode remains optional. TDD: yes for deterministic reference and correction.

Invariants: no yaw step for stale/missing/ambiguous faces; no residual coasting; maximum 1°/s; no correction for errors >8°; manual reset must not restore the previous centre. No claims of solved live drift from unit tests.
Authorization: user specified face as primary centre reference and R for manual alignment. Implement this scoped behaviour without further routine approval.

## Plan
Add FaceHeadingAnchor and behaviour tests; wire Vision capture and status, zero translation for centre mode, route R and camera calibration to face-reference reset; select face mode, test/build/install with backup. Do not change IMU decoding or the legacy glasses algorithm in this task.

## Verification
282 tests passed, including face-centre drift, noise, missing/stale frames, large errors and manual reset. Independent review identified a mode-switch activation bug; centre activation now follows installation of the camera mode and is explicitly enabled during face calibration, disabled when camera stops. Offline replay of 11,825 recorded samples never exceeded 1°/s and requested recenter on large errors. These old face samples exist only when AprilTag associated a face, so their missing-frame rate is not representative of the new face-only path. Physical stability remains unverified with glasses disconnected. No source changes to IMU decoding or legacy glasses correction.
