import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180

private func screen(yaw: Double, pitch: Double = 0, distance: Double = 1.5, width: Double = 1, tilt: Double = 0, roll: Double = 0) -> ScreenPose {
    ScreenPose(yaw: yaw * degree, pitch: pitch * degree, distance: distance, width: width, aspect: 16.0 / 9, tilt: tilt * degree, roll: roll * degree)
}

private func corner(_ pose: ScreenPose, _ side: ScreenSide, top: Bool) -> SIMD3<Double> {
    edgeMidpoint(pose, side) + pose.up * ((top ? 1 : -1) * pose.height / 2)
}

private func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    acos(max(-1, min(1, dot(normalize(a), normalize(b)))))
}

@Test func poseRebuiltFromItsFrameIsTheSame() {
    let pose = screen(yaw: -35, pitch: 16, distance: 1.4, width: 1.3, tilt: 10, roll: 4)
    let rebuilt = ScreenPose(center: pose.center, right: pose.right, up: pose.up, width: pose.width, aspect: pose.aspect)
    for (a, b) in [(rebuilt.yaw, pose.yaw), (rebuilt.pitch, pose.pitch), (rebuilt.distance, pose.distance), (rebuilt.tilt, pose.tilt), (rebuilt.roll, pose.roll)] {
        #expect(abs(a - b) < 1e-9)
    }
}

@Test func rolledAndTiltedScreenStillMapsCornersToUV() {
    let pose = screen(yaw: 20, pitch: 16, distance: 1.4, width: 1.3, tilt: 10, roll: -6)
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

@Test func attachedScreenSharesTheWholeEdgeEvenWhenTilted() {
    let neighbour = screen(yaw: -9, pitch: 16, distance: 1.36, width: 1.3, tilt: 10)
    for side in [ScreenSide.left, .right] {
        let result = attached(screen(yaw: 40, width: 1.3), to: neighbour, on: side)
        for top in [true, false] {
            #expect(length(corner(result, side.opposite, top: top) - corner(neighbour, side, top: top)) < 1e-9)
        }
        let towardHead = normalize(-result.center)
        #expect(abs(dot(towardHead, result.right)) < 1e-9)
        #expect(dot(towardHead, result.normal) > 0.8)
    }
}

@Test func differentWidthScreensMeetAlongTheEdgeLine() {
    let neighbour = screen(yaw: 0, pitch: 16, distance: 1.36, width: 1.6, tilt: 10)
    let result = attached(screen(yaw: -50, width: 1.2), to: neighbour, on: .right)
    #expect(length(edgeMidpoint(result, .left) - edgeMidpoint(neighbour, .right)) < 1e-9)
    #expect(abs(dot(result.up, neighbour.up) - 1) < 1e-9)
    #expect(abs(result.width - 1.2) < 1e-12)
}

@Test func screenNearANeighbourEdgeSticksToIt() {
    let neighbour = screen(yaw: 0, pitch: 5, distance: 1.8, tilt: 10)
    let free = attached(screen(yaw: -30), to: neighbour, on: .right)
    var dragged = free
    dragged.yaw -= 2 * degree
    dragged.pitch += 1 * degree
    let result = snapped(dragged, index: 1, among: [neighbour, dragged], threshold: 3 * degree)
    #expect(result.neighbor == 0)
    #expect(length(edgeMidpoint(result.pose, .left) - edgeMidpoint(neighbour, .right)) < 1e-9)
}

@Test func screenFartherThanTheThresholdStaysWhereItIs() {
    let neighbour = screen(yaw: 0)
    var dragged = attached(screen(yaw: -30), to: neighbour, on: .right)
    dragged.yaw -= 6 * degree
    let result = snapped(dragged, index: 1, among: [neighbour, dragged], threshold: 3 * degree)
    #expect(result.neighbor == nil)
    #expect(result.pose == dragged)
}

@Test func screenAtADifferentHeightDoesNotStick() {
    let neighbour = screen(yaw: 0)
    var dragged = attached(screen(yaw: -30), to: neighbour, on: .right)
    dragged.pitch += 35 * degree
    let result = snapped(dragged, index: 1, among: [neighbour, dragged], threshold: 3 * degree)
    #expect(result.neighbor == nil)
}

@Test func closestNeighbourWins() {
    let left = screen(yaw: 45)
    let right = screen(yaw: -45)
    var dragged = attached(screen(yaw: 0), to: right, on: .left)
    dragged.yaw += 1 * degree
    let result = snapped(dragged, index: 2, among: [left, right, dragged], threshold: 3 * degree)
    #expect(result.neighbor == 1)
}

@Test func arcJoinsEveryPairAlongTheirEdgesInTheSameOrder() {
    let scene = SpatialScene(screens: [
        screen(yaw: -50, pitch: 10, distance: 2.0, width: 1.2, tilt: 20),
        screen(yaw: 60, pitch: -5, distance: 1.2, width: 0.8),
        screen(yaw: 5, pitch: 0, distance: 1.6, width: 1.0, tilt: 10),
    ])
    let head = yawPitchQuat(yaw: 12 * degree, pitch: 16 * degree)
    scene.arrangeInArc(head: head)
    let arc = scene.screens
    #expect(arc[1].yaw > arc[2].yaw && arc[2].yaw > arc[0].yaw)
    #expect(arc.map(\.width) == [1.2, 0.8, 1.0])
    #expect(abs(arc[2].yaw - 12 * degree) < 1e-9 && abs(arc[2].pitch - 16 * degree) < 1e-9)
    #expect(abs(arc[2].distance - 1.6) < 1e-12)
    #expect(length(edgeMidpoint(arc[1], .right) - edgeMidpoint(arc[2], .left)) < 1e-9)
    #expect(length(edgeMidpoint(arc[2], .right) - edgeMidpoint(arc[0], .left)) < 1e-9)
    for pose in arc {
        #expect(abs(dot(pose.up, arc[2].up) - 1) < 1e-9)
        #expect(angle(-pose.center, pose.normal) < 30 * degree)
    }
}
