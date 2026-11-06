import CoreGraphics
import Testing
@testable import RayDeskCore

@Test func displayFamilyIsReadFromTheDisplayName() {
    #expect(glassesDisplayFamily(forDisplayName: "VITURE") == .viture)
    #expect(glassesDisplayFamily(forDisplayName: "RayNeo Air 3s") == .rayNeo)
    #expect(glassesDisplayFamily(forDisplayName: "SmartGlasses") == .rayNeo)
    #expect(glassesDisplayFamily(forDisplayName: "Color LCD") == nil)
}

@Test func vitureUsesItsNativePanelMode() {
    let modes = [
        DisplayModeOption(pointWidth: 1920, pointHeight: 1200, pixelWidth: 1920, pixelHeight: 1200, refreshRate: 120),
        DisplayModeOption(pointWidth: 1920, pointHeight: 1200, pixelWidth: 1920, pixelHeight: 1200, refreshRate: 60),
        DisplayModeOption(pointWidth: 1920, pointHeight: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60),
    ]
    let chosen = chooseGlassesDisplayMode(modes, family: .viture)
    #expect(chosen?.pointHeight == 1200)
    #expect(chosen?.refreshRate == 60)
}

@Test func rayNeoUsesItsNativePanelMode() {
    let modes = [
        DisplayModeOption(pointWidth: 1920, pointHeight: 1200, pixelWidth: 1920, pixelHeight: 1200, refreshRate: 60),
        DisplayModeOption(pointWidth: 1920, pointHeight: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60),
        DisplayModeOption(pointWidth: 1280, pointHeight: 720, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60),
    ]
    #expect(chooseGlassesDisplayMode(modes, family: .rayNeo)?.pointHeight == 1080)
}

@Test func scaledModesAreSkipped() {
    let modes = [DisplayModeOption(pointWidth: 1280, pointHeight: 720, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)]
    #expect(chooseGlassesDisplayMode(modes, family: .rayNeo) == nil)
}

@Test func unusableDesktopModesAreSkipped() {
    let modes = [DisplayModeOption(pointWidth: 1920, pointHeight: 1200, pixelWidth: 1920, pixelHeight: 1200, refreshRate: 60, usableForDesktop: false)]
    #expect(chooseGlassesDisplayMode(modes, family: .viture) == nil)
}

@Test func refreshRateNearestToSixtyWins() {
    let modes = [
        DisplayModeOption(pointWidth: 1920, pointHeight: 1200, pixelWidth: 1920, pixelHeight: 1200, refreshRate: 120),
        DisplayModeOption(pointWidth: 1920, pointHeight: 1200, pixelWidth: 1920, pixelHeight: 1200, refreshRate: 90),
    ]
    #expect(chooseGlassesDisplayMode(modes, family: .viture)?.refreshRate == 90)
}
