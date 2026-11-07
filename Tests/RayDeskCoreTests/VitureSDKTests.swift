import Foundation
import Testing
import simd
@testable import VitureSDK

@Test func poseIsDecodedFromSDKArray() {
    let values: [Float] = [0.1, -0.2, 1.5, 1, 0, 0, 0]
    let pose = values.withUnsafeBufferPointer { buffer in
        ViturePose(floats: buffer.baseAddress!, timestamp: 7, isStable: true)
    }
    #expect(abs(pose.position.x - 0.1) < 1e-6)
    #expect(abs(pose.position.y + 0.2) < 1e-6)
    #expect(abs(pose.position.z - 1.5) < 1e-6)
    #expect(abs(pose.orientation.real - 1) < 1e-6)
    #expect(pose.timestamp == 7)
    #expect(pose.isStable)
}

@Test func poseRoundTripsThroughFloats() {
    let orientation = simd_normalize(simd_quatd(ix: 0.2, iy: 0.3, iz: 0.4, r: 0.5))
    let original = ViturePose(position: SIMD3(1, 2, 3), orientation: orientation, timestamp: 0, isStable: true)
    let values = original.floats
    let decoded = values.withUnsafeBufferPointer { buffer in
        ViturePose(floats: buffer.baseAddress!, timestamp: 0, isStable: true)
    }
    #expect(abs(decoded.position.x - 1) < 1e-6)
    #expect(abs(decoded.position.z - 3) < 1e-6)
    let difference = decoded.orientation * original.orientation.inverse
    #expect(abs(2 * acos(min(1, abs(difference.real)))) < 1e-5)
}

@Test func poseOrientationIsNormalized() {
    let pose = ViturePose(position: .zero, orientation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 2), timestamp: 0, isStable: true)
    #expect(abs(simd_length(pose.orientation.vector) - 1) < 1e-9)
}

@Test func searchPathsStartWithTheDevelopmentDirectory() {
    let paths = VitureLibrary.defaultSearchPaths(bundle: .main, environment: ["VITURE_SDK_DIR": "/tmp/viture-sdk"])
    #expect(paths.first == "/tmp/viture-sdk/libglasses.dylib")
    #expect(paths.contains("/tmp/viture-sdk/aarch64/libglasses.dylib"))
}

@Test func missingLibraryReportsEveryPathItTried() {
    do {
        _ = try VitureLibrary.load(searchPaths: ["/nonexistent/libglasses.dylib"])
        Issue.record("loading a missing library should throw")
    } catch let error as VitureLibrary.LoadError {
        #expect(error == .notFound(["/nonexistent/libglasses.dylib"]))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func usbEnumerationDoesNotFailWithoutGlasses() {
    let devices = VitureUSB.connectedDevices()
    #expect(devices.allSatisfy { $0.productID > 0 })
}

@Test func cacheDirectoryIsCreatedUnderTheGivenBase() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("viture-sdk-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let path = try #require(VitureLibrary.cacheDirectory(base: base))
    #expect(path.hasSuffix("RayDesk/viture"))
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@Test func rotatingYawTurnsTheHeadingAndKeepsPosition() {
    let pose = ViturePose(position: SIMD3(1, 2, 3), orientation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), timestamp: 5, isStable: true)
    let turned = pose.rotatedYaw(by: .pi / 2)
    #expect(abs(turned.orientation.yawPitch.yaw - .pi / 2) < 1e-6)
    #expect(turned.position == pose.position)
    #expect(turned.timestamp == pose.timestamp)
}
