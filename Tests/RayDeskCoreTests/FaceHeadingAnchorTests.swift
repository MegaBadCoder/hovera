import Foundation
import simd
import Testing
@testable import RayDeskCore

private let faceDegree = Double.pi / 180
private func centredFaceAnchor() -> FaceHeadingAnchor {
    var anchor = FaceHeadingAnchor()
    for i in 0..<40 {
        _ = anchor.update(face:SIMD2(0,-25 * faceDegree),headYaw:0,speed:0,time:Double(i)/30,arrival:Double(i)/30+0.09)
    }
    return anchor
}

@Test func faceCentreLearnsAtComfortableCameraHeightAndHoldsWithoutNoiseMotion() {
    var anchor = centredFaceAnchor()
    #expect(anchor.ready)
    var applied = 0.0
    for i in 40..<340 {
        let t=Double(i)/30
        applied += anchor.update(face:SIMD2(0.4 * faceDegree * sin(t*4),-25 * faceDegree),headYaw:0,speed:0,time:t,arrival:t+0.09)
    }
    #expect(abs(applied)<0.01 * faceDegree)
}
@Test func faceCentreCorrectsSlowDriftWithBoundedSteps() {
    var anchor = centredFaceAnchor()
    var yaw=0.0
    for i in 40..<1840 {
        let t=Double(i)/30
        yaw += 0.2 * faceDegree/30
        let step=anchor.update(face:SIMD2(0,-25 * faceDegree),headYaw:yaw,speed:0.2 * faceDegree,time:t,arrival:t+0.09)
        #expect(abs(step)<=faceDegree/30+1e-9)
        yaw += step
    }
    #expect(abs(yaw)<2 * faceDegree)
}
@Test func faceCentreDoesNotChaseLargeErrorsAndManualResetReplacesReference() {
    var anchor = centredFaceAnchor()
    for i in 40..<100 {
        let t=Double(i)/30
        #expect(anchor.update(face:SIMD2(0,-25 * faceDegree),headYaw:39 * faceDegree,speed:0,time:t,arrival:t+0.09)==0)
    }
    #expect(anchor.state == .recenter)
    anchor.reset()
    for i in 100..<150 {
        let t=Double(i)/30
        #expect(anchor.update(face:SIMD2(10 * faceDegree,-20 * faceDegree),headYaw:0,speed:0,time:t,arrival:t+0.09)==0)
    }
    #expect(anchor.ready)
    #expect(anchor.state == .holding)
}
@Test func faceCentreStopsOnMissingStaleOrFastFramesAndDoesNotCoast() {
    var anchor = centredFaceAnchor()
    for i in 40..<100 {
        let t=Double(i)/30
        _ = anchor.update(face:SIMD2(0,-25 * faceDegree),headYaw:3 * faceDegree,speed:0,time:t,arrival:t+0.09)
    }
    #expect(anchor.update(face:nil,headYaw:3 * faceDegree,speed:0,time:4,arrival:4.09)==0)
    #expect(anchor.update(face:SIMD2(0,-25 * faceDegree),headYaw:3 * faceDegree,speed:0,time:4.1,arrival:5)==0)
    #expect(anchor.update(face:SIMD2(0,-25 * faceDegree),headYaw:3 * faceDegree,speed:1,time:5,arrival:5.09)==0)
    #expect(anchor.update(face:SIMD2(0,-25 * faceDegree),headYaw:.nan,speed:0,time:5.1,arrival:5.19)==0)
}
@Test func faceCentreRejectsSingleBadFaceFrameAndStopsWhileTurnedAway() {
    var anchor = centredFaceAnchor()
    #expect(anchor.update(face:SIMD2(5 * faceDegree,-25 * faceDegree),headYaw:0,speed:0,time:1.34,arrival:1.43)==0)
    #expect(anchor.update(face:SIMD2(0,-25 * faceDegree),headYaw:0,speed:0,time:1.37,arrival:1.46)==0)
    #expect(anchor.update(face:SIMD2(30 * faceDegree,-25 * faceDegree),headYaw:30 * faceDegree,speed:0,time:2,arrival:2.09)==0)
    #expect(anchor.update(face:SIMD2(30 * faceDegree,-25 * faceDegree),headYaw:30 * faceDegree,speed:0,time:2.03,arrival:2.12)==0)
    #expect(anchor.state == .turned)
}
