import CoreGraphics
import Testing
@testable import RayDeskCore

private let source = CGRect(x: 0, y: 25, width: 1920, height: 1055)
private let target = CGRect(x: 1920, y: -1000, width: 2560, height: 1415)

@Test func centredWindowStaysCentred() {
    let window = CGRect(x: 460, y: 277.5, width: 1000, height: 550)
    let moved = movedWindowFrame(window, from: source, to: target)
    #expect(moved.size == window.size)
    #expect(abs(moved.midX - target.midX) < 1e-9 && abs(moved.midY - target.midY) < 1e-9)
}

@Test func windowAtTheTopLeftStaysAtTheTopLeft() {
    let window = CGRect(x: 0, y: 25, width: 800, height: 600)
    let moved = movedWindowFrame(window, from: source, to: target)
    #expect(moved.origin == target.origin)
}

@Test func windowAtTheBottomRightStaysThere() {
    let window = CGRect(x: 1120, y: 480, width: 800, height: 600)
    let moved = movedWindowFrame(window, from: source, to: target)
    #expect(moved.maxX == target.maxX && moved.maxY == target.maxY)
}

@Test func windowBiggerThanTheTargetShrinksToFit() {
    let window = CGRect(x: 0, y: 25, width: 1920, height: 1055)
    let small = CGRect(x: -1440, y: 0, width: 1440, height: 875)
    let moved = movedWindowFrame(window, from: source, to: small)
    #expect(moved == small)
}

@Test func windowPartlyOffItsDisplayLandsInsideTheTarget() {
    let window = CGRect(x: -300, y: 900, width: 800, height: 600)
    let moved = movedWindowFrame(window, from: source, to: target)
    #expect(target.contains(moved))
}
