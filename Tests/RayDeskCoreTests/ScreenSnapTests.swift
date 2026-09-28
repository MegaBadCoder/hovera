import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180

private func screen(yaw: Double, pitch: Double = 0, distance: Double = 1.5, width: Double = 1, tilt: Double = 0, roll: Double = 0, pan: Double = 0) -> ScreenPose {
    ScreenPose(yaw: yaw * degree, pitch: pitch * degree, distance: distance, width: width, aspect: 16.0 / 9,
               tilt: tilt * degree, roll: roll * degree, pan: pan * degree)
}

private func corner(_ pose: ScreenPose, _ side: ScreenSide, top: Bool) -> SIMD3<Double> {
    edgeMidpoint(pose, side) + pose.up * ((top ? 1 : -1) * pose.height / 2)
}

private func leftEdge(_ pose: ScreenPose) -> Double { pose.yaw + horizontalHalfAngle(pose) }
private func rightEdge(_ pose: ScreenPose) -> Double { pose.yaw - horizontalHalfAngle(pose) }

@Test func poseRebuiltFromItsFrameIsTheSame() {
    let pose = screen(yaw: -35, pitch: 16, distance: 1.4, width: 1.3, tilt: 10, roll: 4, pan: -12)
    let rebuilt = ScreenPose(center: pose.center, right: pose.right, up: pose.up, width: pose.width, aspect: pose.aspect)
    for (a, b) in [(rebuilt.yaw, pose.yaw), (rebuilt.pitch, pose.pitch), (rebuilt.distance, pose.distance),
                   (rebuilt.tilt, pose.tilt), (rebuilt.roll, pose.roll), (rebuilt.pan, pose.pan)] {
        #expect(abs(a - b) < 1e-9)
    }
}

@Test func turnedAndTiltedScreenStillMapsCornersToUV() {
    let pose = screen(yaw: 20, pitch: 16, distance: 1.4, width: 1.3, tilt: 10, roll: -6, pan: 25)
    let m = pose.modelMatrix
    for (x, y, u, v) in [(-0.99, 0.99, 0.005, 0.005), (0.99, -0.99, 0.995, 0.995), (0.5, 0.5, 0.75, 0.25)] {
        let p = m * SIMD4<Float>(Float(x), Float(y), 0, 1)
        let hit = pose.intersect(rayDirection: SIMD3(Double(p.x), Double(p.y), Double(p.z)))
        #expect(hit != nil)
        if let uv = hit?.uv {
            #expect(abs(uv.x - u) < 1e-4 && abs(uv.y - v) < 1e-4)
        }
    }
}

@Test func gazeJoinPutsScreensSideBySideLikeBefore() {
    let neighbour = screen(yaw: 0, pitch: 5, distance: 1.8, tilt: 10)
    let result = attached(screen(yaw: -40, pitch: 3, roll: 5), to: neighbour, on: .right, join: .gaze)
    #expect(abs(leftEdge(result) - rightEdge(neighbour)) < 1e-9)
    #expect(result.pitch == neighbour.pitch && result.distance == neighbour.distance && result.tilt == neighbour.tilt)
    #expect(result.roll == 0 && result.pan == 0)
}

@Test func hingeJoinSharesTheWholeEdgeEvenWhenTilted() {
    let neighbour = screen(yaw: -9, pitch: 16, distance: 1.36, width: 1.3, tilt: 10)
    for side in [ScreenSide.left, .right] {
        let result = attached(screen(yaw: 40, width: 1.3), to: neighbour, on: side, join: .hinge)
        for top in [true, false] {
            #expect(length(corner(result, side.opposite, top: top) - corner(neighbour, side, top: top)) < 1e-9)
        }
        #expect(abs(dot(normalize(-result.center), result.right)) < 1e-9)
    }
}

@Test func screenNearANeighbourEdgeSticksToIt() {
    let neighbour = screen(yaw: 0, pitch: 5, distance: 1.8, tilt: 10)
    for join in ScreenJoin.allCases {
        var dragged = attached(screen(yaw: -30), to: neighbour, on: .right, join: join)
        dragged.yaw -= 2 * degree
        dragged.pitch += 1 * degree
        let result = snapped(dragged, index: 1, among: [neighbour, dragged], threshold: 3 * degree, join: join)
        #expect(result.neighbor == 0)
        #expect(result.pose == attached(dragged, to: neighbour, on: .right, join: join))
    }
}

@Test func screenFartherThanTheThresholdStaysWhereItIs() {
    let neighbour = screen(yaw: 0)
    var dragged = attached(screen(yaw: -30), to: neighbour, on: .right, join: .gaze)
    dragged.yaw -= 6 * degree
    let result = snapped(dragged, index: 1, among: [neighbour, dragged], threshold: 3 * degree, join: .hinge)
    #expect(result.neighbor == nil)
    #expect(result.pose == dragged)
}

@Test func screenAtADifferentHeightDoesNotStick() {
    let neighbour = screen(yaw: 0)
    var dragged = attached(screen(yaw: -30), to: neighbour, on: .right, join: .gaze)
    dragged.pitch += 35 * degree
    let result = snapped(dragged, index: 1, among: [neighbour, dragged], threshold: 3 * degree, join: .gaze)
    #expect(result.neighbor == nil)
}

@Test func closestNeighbourWins() {
    let left = screen(yaw: 45)
    let right = screen(yaw: -45)
    var dragged = attached(screen(yaw: 0), to: right, on: .left, join: .gaze)
    dragged.yaw += 1 * degree
    let result = snapped(dragged, index: 2, among: [left, right, dragged], threshold: 3 * degree, join: .gaze)
    #expect(result.neighbor == 1)
}

@Test func tripleMonitorArcIsUprightSameSizeAndJoinedAlongTheWholeEdge() {
    let scene = SpatialScene(screens: [
        screen(yaw: -50, pitch: 10, distance: 2.0, width: 1.2, tilt: 20),
        screen(yaw: 60, pitch: -5, distance: 1.2, width: 0.8),
        screen(yaw: 5, pitch: 0, distance: 1.6, width: 1.0, tilt: 10),
    ])
    scene.arrangeInArc(head: yawPitchQuat(yaw: 12 * degree, pitch: 16 * degree), join: .hinge)
    let arc = scene.screens
    #expect(arc[1].yaw > arc[2].yaw && arc[2].yaw > arc[0].yaw)
    #expect(arc.allSatisfy { abs($0.width - 1.0) < 1e-12 })
    #expect(abs(arc[2].yaw - 12 * degree) < 1e-9 && abs(arc[2].pitch - 16 * degree) < 1e-9)
    for pose in arc {
        #expect(abs(pose.up.y - 1) < 1e-9)
        #expect(abs(pose.roll) < 1e-9)
    }
    for top in [true, false] {
        #expect(length(corner(arc[1], .right, top: top) - corner(arc[2], .left, top: top)) < 1e-9)
        #expect(length(corner(arc[2], .right, top: top) - corner(arc[0], .left, top: top)) < 1e-9)
    }
}

@Test func gazeArcKeepsWidthsAndSharesTheMiddleTilt() {
    let scene = SpatialScene(screens: [
        screen(yaw: -50, width: 1.2, tilt: 20),
        screen(yaw: 60, width: 0.8),
        screen(yaw: 5, width: 1.0, tilt: 10),
    ])
    scene.arrangeInArc(head: yawPitchQuat(yaw: 0, pitch: -4 * degree), join: .gaze)
    let arc = scene.screens
    #expect(arc.map(\.width) == [1.2, 0.8, 1.0])
    #expect(arc.allSatisfy { abs($0.tilt - 10 * degree) < 1e-12 && abs($0.pitch + 4 * degree) < 1e-12 })
    #expect(abs(rightEdge(arc[1]) - leftEdge(arc[2])) < 1e-9)
    #expect(abs(rightEdge(arc[2]) - leftEdge(arc[0])) < 1e-9)
}

@Test func foldingASideMonitorKeepsTheSharedEdgeInPlace() {
    let scene = SpatialScene(screens: [screen(yaw: 0, pitch: 10), screen(yaw: -40)])
    scene.arrangeInArc(head: yawPitchQuat(yaw: 0, pitch: 10 * degree), join: .hinge)
    let before = scene.screens[1]
    scene.turn(1, by: 6 * degree)
    let after = scene.screens[1]
    for top in [true, false] {
        #expect(length(corner(after, .left, top: top) - corner(before, .left, top: top)) < 1e-9)
    }
    #expect(abs(acos(dot(after.normal, before.normal)) - 6 * degree) < 1e-9)
}

@Test func turningALoneScreenSpinsItAroundItsMiddle() {
    let scene = SpatialScene(screens: [screen(yaw: 30), screen(yaw: -40)])
    let before = scene.screens[1]
    scene.turn(1, by: -8 * degree)
    let after = scene.screens[1]
    #expect(length(after.center - before.center) < 1e-9)
    #expect(abs(after.pan + 8 * degree) < 1e-9)
}

@Test func tiltingAllTiltsEveryScreenTheSame() {
    let scene = SpatialScene(screens: [screen(yaw: 30, tilt: 5), screen(yaw: -40, tilt: 58)])
    scene.tiltAll(by: 5 * degree)
    #expect(abs(scene.screens[0].tilt - 10 * degree) < 1e-12)
    #expect(abs(scene.screens[1].tilt - 60 * degree) < 1e-12)
}
