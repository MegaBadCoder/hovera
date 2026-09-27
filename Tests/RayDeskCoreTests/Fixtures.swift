import Foundation

enum Fixture {
    static func rows(_ name: String) throws -> [[Double]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        var data = try Data(contentsOf: url)
        if url.pathExtension == "lzfse" {
            data = try (data as NSData).decompressed(using: .lzfse) as Data
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .dropFirst()
            .map { $0.split(separator: ",").map { Double($0)! } }
    }
}
