import Foundation
import CoreGraphics
import simd
import Testing
@testable import RayDeskCore
import RayDeskLocalization

private let wizardDegree = Double.pi / 180
private func sample(_ time: Double, faceYaw: Double = 0, headYaw: Double = 0, speed: Double = 0, quality: Double = 0.9) -> GuidedCameraCalibration.Sample {
    .init(time: time, face: CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.5),
          turn: SIMD2(faceYaw * wizardDegree, 0), head: SIMD2(headYaw * wizardDegree, 0),
          neck: SIMD3(0, 0, 0.5), speed: speed * wizardDegree, quality: quality, latency: 0.08)
}
private func hold(_ model: inout GuidedCameraCalibration, _ time: inout Double, face: Double = 0, head: Double = 0, seconds: Double = 1.2) {
    for _ in 0..<Int(seconds * 30) {
        time += 1.0 / 30
        model.update(sample(time, faceYaw: face, headYaw: head))
    }
}

@Test func guidedCalibrationRequiresBothTurnsAndAValidReturn() throws {
    var model = GuidedCameraCalibration(mode: .turns), time = 0.0
    hold(&model, &time)
    #expect(model.stage == .left)
    #expect(model.result == nil)
    hold(&model, &time, face: 22, head: 20)
    #expect(model.stage == .middle)
    hold(&model, &time)
    #expect(model.stage == .right)
    hold(&model, &time, face: -22, head: -20)
    #expect(model.stage == .returning)
    #expect(model.result == nil)
    hold(&model, &time)
    let result = try #require(model.result)
    #expect(model.stage == .complete)
    #expect(abs(result.yawScale - 1.1) < 1e-9)
    #expect(result.returnError < 1e-9)
}

@Test func guidedCalibrationRejectsReturnDriftAndAsymmetricTurns() {
    var model = GuidedCameraCalibration(mode: .turns), time = 0.0
    hold(&model, &time)
    hold(&model, &time, face: 22, head: 20)
    hold(&model, &time)
    hold(&model, &time, face: -22, head: -20)
    hold(&model, &time, head: 4)
    #expect(model.stage == .failed)
    #expect(model.result == nil)
    model = GuidedCameraCalibration(mode: .turns); time = 0
    hold(&model, &time)
    hold(&model, &time, face: 22, head: 20)
    hold(&model, &time)
    hold(&model, &time, face: -22, head: -15)
    #expect(model.stage == .failed)
}

@Test func guidedCalibrationNeverUsesFastMissingOrStaleFrames() {
    for kind in 0..<4 {
        var model = GuidedCameraCalibration(mode: .turns)
        for i in 0..<90 {
            var value = sample(Double(i) / 30)
            if kind == 0 { value.face = nil }
            if kind == 1 { value.speed = 20 * wizardDegree }
            if kind == 2 { value.latency = 0.4 }
            if kind == 3 { value.quality = 0.2 }
            model.update(value)
        }
        #expect(model.stage == .position)
        #expect(model.progress == 0)
        #expect(model.result == nil)
    }
}

@Test func guidedCalibrationLossResetsDwellAndInvalidationDiscardsResult() {
    var model = GuidedCameraCalibration(mode: .turns), time = 0.0
    hold(&model, &time, seconds: 0.7)
    model.interrupt()
    hold(&model, &time, seconds: 0.5)
    #expect(model.stage == .position)
    #expect(model.progress < 0.6)
    hold(&model, &time)
    hold(&model, &time, face: 22, head: 20)
    hold(&model, &time)
    hold(&model, &time, face: -22, head: -20)
    hold(&model, &time)
    #expect(model.result != nil)
    model.invalidate(.calibrationCameraSettingsChanged)
    #expect(model.result == nil)
    #expect(model.stage == .failed)
}

@Test func guidedCalibrationHandlesWorldYawWrap() throws {
    var model = GuidedCameraCalibration(mode: .turns), time = 0.0
    hold(&model, &time, head: 179)
    hold(&model, &time, face: 22, head: -161)
    hold(&model, &time, head: 179)
    hold(&model, &time, face: -22, head: 159)
    hold(&model, &time, head: 179)
    #expect(abs(try #require(model.result).yawScale - 1.1) < 1e-9)
}

@Test func guidedCalibrationRestartsAfterLostTrackingOrLongSideHold() {
    for missing in [true, false] {
        var model = GuidedCameraCalibration(mode: .turns), time = 0.0
        hold(&model, &time)
        #expect(model.stage == .left)
        if missing {
            model.checkTimeout(at: time + 2.1)
        } else {
            hold(&model, &time, face: 11, seconds: 13)
        }
        #expect(model.stage == .position)
        #expect(model.result == nil)
    }
}

@Test func guidedCalibrationChecksIntermediateCenterBeforeRightTurn() {
    var model = GuidedCameraCalibration(mode: .turns), time = 0.0
    hold(&model, &time)
    hold(&model, &time, face: 16.5, head: 15)
    #expect(model.stage == .middle)
    hold(&model, &time, face: -16.5, head: -15)
    #expect(model.stage == .middle)
    hold(&model, &time, head: 4)
    #expect(model.stage == .position)
    #expect(model.result == nil)
}

@Test func guidedCalibrationAcceptsSmallerTurns() throws {
    var model = GuidedCameraCalibration(mode: .turns), time = 0.0
    hold(&model, &time)
    hold(&model, &time, face: 16.5, head: 15)
    hold(&model, &time)
    hold(&model, &time, face: -16.5, head: -15)
    hold(&model, &time)
    #expect(abs(try #require(model.result).yawScale - 1.1) < 1e-9)
}

@Test func centerCalibrationNeedsNoSideTurns() throws {
    var model = GuidedCameraCalibration(), time = 0.0
    hold(&model, &time, face: 3, head: 17)
    let result = try #require(model.result)
    #expect(model.stage == .complete)
    #expect(abs(result.cameraYaw / wizardDegree - 14) < 1e-9)
    #expect(result.yawScale == 1)
    #expect(!result.checkedTurns)
}

@Test func centerCalibrationRejectsMovementAndMissingFace() {
    for missing in [false, true] {
        var model = GuidedCameraCalibration()
        for i in 0..<90 {
            var value = sample(Double(i) / 30, speed: missing ? 0 : 20)
            if missing { value.face = nil }
            model.update(value)
        }
        #expect(model.result == nil)
        #expect(model.stage == .position)
    }
}

@Test func centerCalibrationCanBeInvalidatedBeforeApplying() {
    var model = GuidedCameraCalibration(), time = 0.0
    hold(&model, &time)
    #expect(model.result != nil)
    model.invalidate(.calibrationCameraSettingsChanged)
    #expect(model.result == nil)
}

@Test func centerCalibrationNeverAppliesAnOldReadyMeasurement() {
    var model = GuidedCameraCalibration(), time = 0.0
    hold(&model, &time)
    #expect(model.result != nil)
    model.checkTimeout(at: time + 0.6)
    #expect(model.result == nil)
    hold(&model, &time)
    #expect(model.result != nil)
    model.update(sample(time + 0.033, speed: 20))
    #expect(model.result == nil)
}
