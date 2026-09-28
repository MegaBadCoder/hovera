import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180

private func screen(yaw: Double, pitch: Double = 0, distance: Double = 1.5, width: Double = 1, tilt: Double = 0) -> ScreenPose {
    ScreenPose(yaw: yaw * degree, pitch: pitch * degree, distance: distance, width: width, aspect: 16.0 / 9, tilt: tilt * degree)
}

private func leftEdge(_ pose: ScreenPose) -> Double { pose.yaw + horizontalHalfAngle(pose) }
private func rightEdge(_ pose: ScreenPose) -> Double { pose.yaw - horizontalHalfAngle(pose) }

@Test func screenNearTheRightEdgeOfANeighbourSticksToIt() {
    let neighbour = screen(yaw: 0, pitch: 5, distance: 1.8, tilt: 10)
    let half = horizontalHalfAngle(neighbour) / degree
    let dragged = screen(yaw: -(2 * half + 2), pitch: 3, distance: 1.5)
    let result = snapped(dragged, index: 1, among: [neighbour, dragged], threshold: 3 * degree)
    #expect(result.neighbor == 0)
    #expect(abs(leftEdge(result.pose) - rightEdge(neighbour)) < 1e-9)
    #expect(result.pose.pitch == neighbour.pitch)
    #expect(result.pose.distance == neighbour.distance)
    #expect(result.pose.tilt == neighbour.tilt)
    #expect(result.pose.width == dragged.width)
}

@Test func screenNearTheLeftEdgeSticksOnTheLeft() {
    let neighbour = screen(yaw: 10)
    let dragged = screen(yaw: 10 + 2 * horizontalHalfAngle(neighbour) / degree + 1.5)
    let result = snapped(dragged, index: 0, among: [dragged, neighbour], threshold: 3 * degree)
    #expect(result.neighbor == 1)
    #expect(abs(rightEdge(result.pose) - leftEdge(neighbour)) < 1e-9)
}

@Test func screenFartherThanTheThresholdStaysWhereItIs() {
    let neighbour = screen(yaw: 0)
    let dragged = screen(yaw: -(2 * horizontalHalfAngle(neighbour) / degree + 5))
    let result = snapped(dragged, index: 1, among: [neighbour, dragged], threshold: 3 * degree)
    #expect(result.neighbor == nil)
    #expect(result.pose == dragged)
}

@Test func screenAtADifferentHeightDoesNotStick() {
    let neighbour = screen(yaw: 0, pitch: 0)
    let dragged = screen(yaw: -(2 * horizontalHalfAngle(neighbour) / degree + 1), pitch: 35)
    let result = snapped(dragged, index: 1, among: [neighbour, dragged], threshold: 3 * degree)
    #expect(result.neighbor == nil)
}

@Test func slightOverlapAlsoSticks() {
    let neighbour = screen(yaw: 0)
    let dragged = screen(yaw: -(2 * horizontalHalfAngle(neighbour) / degree - 2))
    let result = snapped(dragged, index: 1, among: [neighbour, dragged], threshold: 3 * degree)
    #expect(result.neighbor == 0)
    #expect(abs(leftEdge(result.pose) - rightEdge(neighbour)) < 1e-9)
}

@Test func closestNeighbourWins() {
    let left = screen(yaw: 40)
    let right = screen(yaw: -40)
    let gapToRight = 1.0
    let dragged = screen(yaw: -40 + 2 * horizontalHalfAngle(right) / degree + gapToRight)
    let result = snapped(dragged, index: 2, among: [left, right, dragged], threshold: 3 * degree)
    #expect(result.neighbor == 1)
}

@Test func arcPutsScreensEdgeToEdgeInTheSameOrder() {
    let scene = SpatialScene(screens: [
        screen(yaw: -50, pitch: 10, distance: 2.0, width: 1.2, tilt: 20),
        screen(yaw: 60, pitch: -5, distance: 1.2, width: 0.8),
        screen(yaw: 5, pitch: 0, distance: 1.6, width: 1.0),
    ])
    let head = yawPitchQuat(yaw: 12 * degree, pitch: -4 * degree)
    scene.arrangeInArc(head: head)
    let arc = scene.screens
    #expect(arc[1].yaw > arc[2].yaw && arc[2].yaw > arc[0].yaw)
    #expect(Set(arc.map(\.distance)) == [1.6])
    #expect(arc.allSatisfy { abs($0.pitch + 4 * degree) < 1e-12 && $0.tilt == 0 })
    #expect(arc.map(\.width) == [1.2, 0.8, 1.0])
    #expect(abs(rightEdge(arc[1]) - leftEdge(arc[2])) < 1e-9)
    #expect(abs(rightEdge(arc[2]) - leftEdge(arc[0])) < 1e-9)
    let middle = (leftEdge(arc[1]) + rightEdge(arc[0])) / 2
    #expect(abs(middle - 12 * degree) < 1e-9)
}
