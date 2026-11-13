import Foundation
import Testing
@testable import VitureSDK

final class TestVitureSDK {
    let library: VitureLibrary
    private let handle: UnsafeMutableRawPointer
    private let directory: URL

    init(includesNativePose: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SDK/viture.c")
        let path = directory.appendingPathComponent("libtest.dylib").path
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-dynamiclib", source.path, "-o", path]
        if !includesNativePose { compiler.arguments?.append("-DOMIT_NATIVE_POSE") }
        try compiler.run()
        compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)
        library = try VitureLibrary(path: path)
        handle = try #require(dlopen(path, RTLD_NOW | RTLD_LOCAL))
    }

    deinit {
        dlclose(handle)
        try? FileManager.default.removeItem(at: directory)
    }

    func symbol<T>(_ name: String, as type: T.Type) -> T {
        unsafeBitCast(dlsym(handle, name)!, to: type)
    }

    var trace: Int32 { symbol("test_trace", as: (@convention(c) () -> Int32).self)() }
    func fail(at stage: Int32) { symbol("test_failure", as: (@convention(c) (Int32) -> Void).self)(stage) }
}

@Suite(.serialized)
struct VitureIntegrationTests {}

extension VitureIntegrationTests {
    struct Lifecycle {
        @Test func shutdownFollowsAnExplicitStop() throws {
            let sdk = try TestVitureSDK()
            var device: VitureDevice? = sdk.library.createDevice(productID: 0x1104)
            #expect(device != nil)
            #expect(device?.initialize() == true)
            #expect(device?.start() == true)
            #expect(device?.stop() == true)
            device = nil
            #expect(sdk.trace == 123456)
        }

        @Test func failedStartStillShutsDown() throws {
            let sdk = try TestVitureSDK()
            sdk.fail(at: 3)
            var device: VitureDevice? = sdk.library.createDevice(productID: 0x1104)
            #expect(device != nil)
            #expect(device?.initialize() == true)
            #expect(device?.start() == false)
            device = nil
            #expect(sdk.trace == 123456)
        }

        @Test func destroyingDeviceReleasesCallbacks() throws {
            final class Token {}
            let sdk = try TestVitureSDK()
            weak var released: Token?
            do {
                let token = Token()
                released = token
                let device = try #require(sdk.library.createDevice(productID: 0x1104))
                let registered = device.registerCallbacks(imu: { [token] _, _, _ in _ = token })
                #expect(registered)
            }
            #expect(released == nil)
        }
    }
}
