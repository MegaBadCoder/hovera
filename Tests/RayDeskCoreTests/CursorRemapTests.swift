import CoreGraphics
import Testing
@testable import RayDeskCore

private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let panels = [CGRect(x: -1164, y: -1080, width: 1920, height: 1080), CGRect(x: 756, y: -1080, width: 1920, height: 1080)]
private let glasses = CGRect(x: -2764, y: -1080, width: 1600, height: 900)

private func remap(_ previous: CGPoint, _ proposed: CGPoint, dy: Double, preferred: Int? = nil) -> CGPoint? {
    remappedCursor(previous: previous, proposed: proposed, delta: CGVector(dx: 0, dy: dy),
                   panels: panels, main: main, glasses: glasses, preferredPanel: preferred)
}

@Test func cursorNeverEntersTheGlassesDisplay() {
    #expect(remap(CGPoint(x: -1160, y: -500), CGPoint(x: -1170, y: -500), dy: 0) == CGPoint(x: -1160, y: -500))
}

@Test func pushingDownAtAFreeBottomEdgeGoesToMacProportionally() throws {
    let point = try #require(remap(CGPoint(x: -1000, y: -1), CGPoint(x: -1000, y: -1), dy: 5))
    #expect(abs(point.x - (1000.0 - 836.0) / 1920 * 1512) < 0.5)
    #expect(point.y == 1)
}

@Test func macOSCrossingDownIsMadeProportional() throws {
    let point = try #require(remap(CGPoint(x: 100, y: -1), CGPoint(x: 100, y: 3), dy: 4))
    #expect(abs(point.x - 1264.0 / 1920 * 1512) < 0.5)
    #expect(point.y == 1)
}

@Test func goingUpFromMacLandsOnPanelUnderGaze() throws {
    let point = try #require(remap(CGPoint(x: 200, y: 0.5), CGPoint(x: 200, y: -2), dy: -3, preferred: 1))
    #expect(abs(point.x - (756 + 200.0 / 1512 * 1920)) < 0.5)
    #expect(point.y == -1)
}

@Test func goingUpFromMacWithoutGazeUsesThePanelMacOSChose() throws {
    let point = try #require(remap(CGPoint(x: 200, y: 0.5), CGPoint(x: 200, y: -2), dy: -3))
    #expect(abs(point.x - (-1164 + 200.0 / 1512 * 1920)) < 0.5)
}

@Test func sidewaysBetweenPanelsAndOrdinaryMovesAreLeftAlone() {
    #expect(remap(CGPoint(x: 755, y: -500), CGPoint(x: 757, y: -500), dy: 0) == nil)
    #expect(remap(CGPoint(x: 0, y: -500), CGPoint(x: 5, y: -495), dy: 5) == nil)
    #expect(remap(CGPoint(x: 700, y: 500), CGPoint(x: 705, y: 505), dy: 5) == nil)
}
