import Testing
import CoreGraphics
@testable import RayDeskCore

private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
}

@Test func globalPointMapsUVToBoundsCorners() {
    let bounds = CGRect(x: 100, y: 50, width: 200, height: 100)
    #expect(globalPoint(uv: SIMD2(0, 0), in: bounds) == CGPoint(x: 100, y: 50))
    #expect(globalPoint(uv: SIMD2(1, 1), in: bounds) == CGPoint(x: 300, y: 150))
    #expect(globalPoint(uv: SIMD2(0.5, 0.5), in: bounds) == CGPoint(x: 200, y: 100))
}

@Test func uvOfPointOutsideBoundsIsNil() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(uv(of: CGPoint(x: -1, y: 50), in: bounds) == nil)
    #expect(uv(of: CGPoint(x: 100, y: 50), in: bounds) == nil)
    #expect(uv(of: CGPoint(x: 50, y: 100), in: bounds) == nil)
}

@Test func uvRoundtripsThroughGlobalPoint() {
    let bounds = CGRect(x: 10, y: 20, width: 300, height: 150)
    let original = SIMD2<Double>(0.37, 0.82)
    let point = globalPoint(uv: original, in: bounds)
    let recovered = uv(of: point, in: bounds)
    #expect(recovered != nil)
    if let recovered {
        #expect(abs(recovered.x - original.x) < 1e-9)
        #expect(abs(recovered.y - original.y) < 1e-9)
    }
}

@Test func arrangeDisplaysOrdersRowByDescendingYaw() {
    let main = CGRect(x: 0, y: 500, width: 1440, height: 900)
    let yaws = [10.0, 30.0, -10.0].map { $0 * .pi / 180 }
    let sizes = [CGSize(width: 400, height: 300), CGSize(width: 400, height: 300), CGSize(width: 400, height: 300)]
    let result = arrangeDisplays(screenYaws: yaws, screenSizes: sizes, main: main, glasses: CGSize(width: 300, height: 200))
    #expect(result.screens.count == 3)
    #expect(result.screens[1].x < result.screens[0].x)
    #expect(result.screens[0].x < result.screens[2].x)
}

@Test func arrangeDisplaysScreensAreAdjacentAndTouchMainTop() {
    let main = CGRect(x: 0, y: 500, width: 1440, height: 900)
    let yaws = [20.0, 0.0, -20.0].map { $0 * .pi / 180 }
    let sizes = [CGSize(width: 400, height: 300), CGSize(width: 500, height: 350), CGSize(width: 350, height: 250)]
    let result = arrangeDisplays(screenYaws: yaws, screenSizes: sizes, main: main, glasses: CGSize(width: 300, height: 200))

    let order = [0, 1, 2]
    for i in 0..<(order.count - 1) {
        let a = result.screens[order[i]]
        let b = result.screens[order[i + 1]]
        #expect(a.x + sizes[order[i]].width == b.x)
    }
    for i in 0..<order.count {
        let origin = result.screens[order[i]]
        let bottom = origin.y + sizes[order[i]].height
        #expect(abs(bottom - main.minY) < 1)
    }
}

@Test func arrangeDisplaysGlassesLeftOfRowTopAlignedKeepsMainBottomEdgeFree() {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let sizes = [CGSize(width: 1920, height: 1080), CGSize(width: 1920, height: 1080)]
    let glasses = CGSize(width: 1600, height: 900)
    let result = arrangeDisplays(screenYaws: [0.4, -0.4], screenSizes: sizes, main: main, glasses: glasses)

    let rowLeft = result.screens.map(\.x).min()!
    let rowTop = result.screens.map(\.y).min()!
    #expect(result.glasses == CGPoint(x: rowLeft - glasses.width, y: rowTop))
    let glassesRect = CGRect(origin: result.glasses, size: glasses)
    #expect(glassesRect.maxY <= main.minY || glassesRect.minX >= main.maxX || glassesRect.maxX <= main.minX)
    #expect(glassesRect.minY < main.maxY)
}

@Test func arrangeDisplaysNoPairwiseOverlapForVaryingScreenCounts() {
    let main = CGRect(x: 0, y: 500, width: 1440, height: 900)
    let glassesSize = CGSize(width: 300, height: 200)

    for count in 1...4 {
        let yaws = (0..<count).map { Double($0 * 15 - 20) * .pi / 180 }
        let sizes = (0..<count).map { CGSize(width: 300 + $0 * 20, height: 200 + $0 * 10) }
        let result = arrangeDisplays(screenYaws: yaws, screenSizes: sizes, main: main, glasses: glassesSize)

        var rects: [CGRect] = [main, CGRect(origin: result.glasses, size: glassesSize)]
        for i in 0..<count {
            rects.append(CGRect(origin: result.screens[i], size: sizes[i]))
        }

        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                #expect(!overlaps(rects[i], rects[j]))
            }
        }
    }
}
