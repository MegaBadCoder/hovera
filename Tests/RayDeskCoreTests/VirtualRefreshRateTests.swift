import Testing
@testable import RayDesk

@Test func vitureVirtualMonitorsAdvertise120Hz() {
    let settings = VirtualScreen.settings(width: 1920, height: 1080, family: .viture)
    #expect(settings.modes.count == 1)
    #expect(settings.modes.first?.refreshRate == 120)
    #expect(settings.modes.first?.width == 1920)
    #expect(settings.modes.first?.height == 1080)
    #expect(settings.hiDPI == 0)
}

@Test func rayNeoVirtualMonitorsAdvertise120Hz() {
    #expect(VirtualScreen.settings(width: 1920, height: 1080, family: .rayNeo).modes.first?.refreshRate == 120)
    #expect(VirtualScreen.settings(width: 1920, height: 1080, family: nil).modes.first?.refreshRate == 60)
}
