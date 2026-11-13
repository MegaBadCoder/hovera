import AppKit
import Testing
@testable import RayDesk

@Suite(.serialized) @MainActor struct PictureStabilizationMenuTests {
    @Test func anchoredLevelsAreAvailableAndReflectTheActiveFilter() throws {
        try withSettings {
            UserDefaults.standard.set(true, forKey: "worldLockedPresentation")
            UserDefaults.standard.set(true, forKey: "adaptiveVSync")
            UserDefaults.standard.set(true, forKey: "restSmoothing")
            UserDefaults.standard.set("strong", forKey: "restStrength")
            let menu = try stabilizationMenu(AppDelegate())
            #expect(menu.isEnabled)
            #expect(menu.submenu?.items.count == 4)
            #expect(menu.submenu?.items.first { $0.state == .on }?.representedObject as? String == "off")
        }
    }

    @Test func selectingAnAnchoredLevelUsesTheRestFilterWithoutLosingWorldLock() throws {
        try withSettings {
            UserDefaults.standard.set(true, forKey: "worldLockedPresentation")
            UserDefaults.standard.set(true, forKey: "adaptiveVSync")
            UserDefaults.standard.set(false, forKey: "restSmoothing")
            UserDefaults.standard.set("weak", forKey: "stabilization")
            let delegate = AppDelegate()
            for (level, strength) in [("weak", "light"), ("medium", "medium"), ("strong", "strong")] {
                let menu = try stabilizationMenu(delegate)
                let item = try #require(menu.submenu?.items.first { $0.representedObject as? String == level })
                #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
                #expect(UserDefaults.standard.bool(forKey: "worldLockedPresentation"))
                #expect(UserDefaults.standard.bool(forKey: "restSmoothing"))
                #expect(!UserDefaults.standard.bool(forKey: "adaptiveVSync"))
                #expect(UserDefaults.standard.string(forKey: "restStrength") == strength)
                #expect(UserDefaults.standard.string(forKey: "stabilization") == "weak")
                let rebuilt = try stabilizationMenu(delegate)
                #expect(rebuilt.submenu?.items.filter { $0.state == .on }.count == 1)
                #expect(rebuilt.submenu?.items.first { $0.state == .on }?.representedObject as? String == level)
            }
        }
    }

    @Test func disablingTheFilterPreservesAnchoringAndScanout() throws {
        try withSettings {
            UserDefaults.standard.set(true, forKey: "worldLockedPresentation")
            UserDefaults.standard.set(false, forKey: "adaptiveVSync")
            UserDefaults.standard.set(true, forKey: "restSmoothing")
            let delegate = AppDelegate()
            let menu = try stabilizationMenu(delegate)
            let item = try #require(menu.submenu?.items.first { $0.representedObject as? String == "off" })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            #expect(!UserDefaults.standard.bool(forKey: "restSmoothing"))
            #expect(UserDefaults.standard.bool(forKey: "worldLockedPresentation"))
            let picture = try #require(delegate.buildMenu().items.compactMap(\.submenu).first { menu in
                menu.items.contains { $0.action == NSSelectorFromString("toggleScanoutCompensation:") }
            })
            #expect(picture.items.first { $0.action == NSSelectorFromString("toggleScanoutCompensation:") }?.state == .on)
        }
    }

    @Test func unanchoredLevelsKeepTheExistingOrientationFilter() throws {
        try withSettings {
            UserDefaults.standard.set(false, forKey: "worldLockedPresentation")
            UserDefaults.standard.set(true, forKey: "adaptiveVSync")
            UserDefaults.standard.set(false, forKey: "restSmoothing")
            let delegate = AppDelegate()
            let menu = try stabilizationMenu(delegate)
            let item = try #require(menu.submenu?.items.first { $0.representedObject as? String == "medium" })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            #expect(UserDefaults.standard.string(forKey: "stabilization") == "medium")
            #expect(!UserDefaults.standard.bool(forKey: "worldLockedPresentation"))
            #expect(UserDefaults.standard.bool(forKey: "adaptiveVSync"))
            #expect(!UserDefaults.standard.bool(forKey: "restSmoothing"))
        }
    }

    private func stabilizationMenu(_ delegate: AppDelegate) throws -> NSMenuItem {
        _ = NSApplication.shared
        return try #require(delegate.buildMenu().items.compactMap(\.submenu).flatMap(\.items).first { item in
            item.submenu?.items.contains { $0.action == NSSelectorFromString("chooseStabilization:") } == true
        })
    }

    private func withSettings(_ body: () throws -> Void) rethrows {
        let keys = ["worldLockedPresentation", "adaptiveVSync", "restSmoothing", "restStrength", "stabilization"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        }
        try body()
    }
}
