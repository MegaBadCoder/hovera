import Testing
import simd
import Foundation
@testable import AprilTagTracking

private func pose(_ x: Double = 0, yaw: Double = 0) -> TagPose {
    TagPose(rotation: simd_quatd(angle: yaw, axis: SIMD3(0,1,0)), position: SIMD3(x,0,0.5))
}
@Test func tagPoseCompositionRoundTrips() {
    let p = pose(0.08, yaw: 0.6)
    let identity = p.composed(with: p.inverse)
    #expect(simd_length(identity.position) < 1e-9)
    #expect(abs(identity.rotation.angle) < 1e-9)
}
@Test func tagRigRequiresFrontBeforeUsingSide() {
    var rig = AprilTagRig()
    #expect(rig.update([TagObservation(id: 1, pose: pose())], time: 0) == nil)
    #expect(rig.update([TagObservation(id: 0, pose: pose())], time: 0.03)?.id == 0)
}
@Test func sideTagKeepsSameRootPoseAfterOverlapCalibration() throws {
    var rig = AprilTagRig()
    let offset = TagPose(rotation: simd_quatd(angle: 1, axis: SIMD3(0,1,0)), position: SIMD3(0.07,0,0.04))
    for n in 0..<30 {
        let root = pose(0.01, yaw: 0.2)
        _ = rig.update([.init(id: 0, pose: root), .init(id: 1, pose: root.composed(with: offset))], time: Double(n)/30)
    }
    #expect(rig.knownIDs.contains(1))
    let moved = pose(0.03, yaw: -0.1)
    let reading = rig.update([.init(id: 1, pose: moved.composed(with: offset))], time: 1.01)
    let result = try #require(reading)
    #expect(simd_distance(result.pose.position, moved.position) < 1e-8)
    #expect(abs((result.pose.rotation.inverse * moved.rotation).angle) < 1e-8)
    #expect(rig.update([], time: 1.04) == nil)
    rig.reset()
    #expect(rig.update([.init(id: 1, pose: moved)], time: 2) == nil)
}
@Test func tagRigRejectsDuplicatesAndUnknownIDs() {
    var rig = AprilTagRig()
    #expect(rig.update([.init(id: 0, pose: pose()), .init(id: 0, pose: pose(0.1))], time: 0) == nil)
    #expect(rig.update([.init(id: 9, pose: pose())], time: 0.03) == nil)
}

private let printedTags = ["0000000000011111111001001010100110001010011001111001010111100110100110011110111001111111100000000000", "0000000000011111111001001001100110100010010000111001100111100101001010011101101001111111100000000000", "0000000000011111111001001000100110110110010111111001110110100111101110011100011001111111100000000000"]

@Test func detectorReadsAllThreePrintedIDsAndMetricSize() throws {
    let detector = try #require(AprilTagDetector())
    var gray = [UInt8](repeating: 255, count: 320*240)
    for id in 0..<3 {
        let bits = Array(printedTags[id])
        for y in 0..<40 { for x in 0..<40 {
            gray[(100+y)*320 + 40+id*80+x] = bits[(y/4)*10+x/4] == "1" ? 0 : 255
        }}
    }
    let results = detector.detect(gray: gray, width: 320, height: 240,
        intrinsics: .init(fx: 640, fy: 640, cx: 160, cy: 120), size: 0.025)
    #expect(Set(results.map(\.id)) == [0,1,2])
    for tag in results { #expect(abs(tag.pose.position.z - 0.5) < 0.02) }
    #expect(detector.detect(gray: [UInt8](repeating:255,count:320*240),width:320,height:240,
        intrinsics:.init(fx:640,fy:640,cx:160,cy:120),size:0.025).isEmpty)
}

@Test func tagAnchorCalibratesThenHoldsOnLossAndRejectsStaleFrames() throws {
    var anchor = AprilTagAnchor()
    let head = simd_quatd(angle: 0, axis: SIMD3(0,1,0))
    for n in 0..<40 { _ = anchor.update(pose: pose(), time: Double(n)/30, arrival: Double(n)/30+0.07, head: head, speed: 0) }
    #expect(anchor.ready)
    let reading = anchor.update(pose: pose(0.02), time: 1.4, arrival: 1.47, head: head, speed: 0)
    let value = try #require(reading)
    #expect(value.offset.x < 0)
    #expect(abs(value.targetYaw) < 1e-8)
    let held = anchor.offset
    #expect(anchor.update(pose: nil, time: 1.5, arrival: 1.57, head: head, speed: 0) == nil)
    #expect(anchor.offset == held)
    #expect(anchor.update(pose: pose(0.1), time: 1.6, arrival: 2, head: head, speed: 0) == nil)
    #expect(anchor.offset == held)
    anchor.rotateWorld(by: 0.2)
    let rotated = anchor.update(pose: pose(0.02), time: 2.1, arrival: 2.17, head: head, speed: 0)
    #expect(abs((rotated?.targetYaw ?? 99)-0.2) < 1e-8)
}
@Test func tagAnchorCannotCalibrateWhileMoving() {
    var anchor = AprilTagAnchor()
    for n in 0..<60 { _ = anchor.update(pose: pose(), time: Double(n)/30, arrival: Double(n)/30+0.05,
        head: simd_quatd(angle:0,axis:SIMD3(0,1,0)), speed: 0.5) }
    #expect(!anchor.ready)
}

@Test func detectorRecoversTiltedPrintedMarkerPose() throws {
    let detector = try #require(AprilTagDetector())
    let width=640, height=480, f=800.0, size=0.04
    let rotation=simd_quatd(angle:25 * .pi/180,axis:SIMD3(0,1,0))
    let position=SIMD3<Double>(0.02,-0.01,0.5)
    let localPosition=rotation.inverse.act(position)
    let bits=Array(printedTags[0])
    var gray=[UInt8](repeating:255,count:width*height)
    for y in 0..<height { for x in 0..<width {
        let ray=rotation.inverse.act(SIMD3((Double(x)+0.5-320)/f,(Double(y)+0.5-240)/f,1))
        let distance=localPosition.z/ray.z
        let local=distance*ray-localPosition
        let gx=Int(floor(local.x/size*8+5)), gy=Int(floor(local.y/size*8+5))
        if (0..<10).contains(gx), (0..<10).contains(gy), bits[gy*10+gx]=="1" { gray[y*width+x]=0 }
    }}
    let detections=detector.detect(gray:gray,width:width,height:height,
        intrinsics:.init(fx:f,fy:f,cx:320,cy:240),size:size)
    let tag=try #require(detections.first)
    #expect(tag.id==0)
    #expect(simd_distance(tag.pose.position,position)<0.01)
    #expect(tag.pose.distance(to:.init(rotation:rotation,position:position)).radians<3 * .pi/180)
}

@Test func tagMotionRejectsUnobservedPitchAndRollWithoutLearningTheJump() {
    var gate = AprilTagMotionGate()
    let zero = simd_quatd(angle:0,axis:SIMD3(0,1,0))
    #expect(gate.accept(tag:zero,head:zero,time:0) == true)
    for (index,axis) in [SIMD3<Double>(1,0,0),SIMD3<Double>(0,0,1)].enumerated() {
        let jump = simd_quatd(angle:58 * .pi/180,axis:axis)
        #expect(gate.accept(tag:jump,head:zero,time:Double(index+1)/30) == false)
    }
    #expect(gate.accept(tag:zero,head:zero,time:0.1) == true)
}
@Test func tagMotionAcceptsRealCombinedRotationAndSurvivesWorldRecenter() {
    var gate = AprilTagMotionGate()
    let mount = simd_quatd(angle:.pi,axis:SIMD3(0,0,1))
    let camera = simd_quatd(angle:0.4,axis:simd_normalize(SIMD3(1,2,3)))
    let start = simd_quatd(angle:0,axis:SIMD3(0,1,0))
    #expect(gate.accept(tag:camera * start * mount.inverse,head:start,time:0) == true)
    let head = simd_quatd(angle:0.8,axis:simd_normalize(SIMD3(2,1,3)))
    let tag = camera * head * mount.inverse
    #expect(gate.accept(tag:tag,head:head,time:0.03) == true)
    gate.rotateWorld(by:0.6)
    let world = simd_quatd(angle:0.6,axis:SIMD3(0,1,0))
    #expect(gate.accept(tag:tag,head:world * head,time:0.06) == true)
}
@Test func tagMotionDoesNotAdoptWrongPoseAfterGapOrInvalidInput() {
    var gate = AprilTagMotionGate()
    let zero = simd_quatd(angle:0,axis:SIMD3(0,1,0))
    #expect(gate.accept(tag:zero,head:zero,time:0) == true)
    #expect(gate.accept(tag:zero,head:zero,time:0) == false)
    #expect(gate.accept(tag:simd_quatd(vector:SIMD4(repeating:Double.nan)),head:zero,time:0.1) == false)
    #expect(gate.accept(tag:simd_quatd(angle:1,axis:SIMD3(1,0,0)),head:zero,time:5) == false)
    #expect(gate.accept(tag:zero,head:zero,time:5.1) == true)
}
