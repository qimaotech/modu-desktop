import Foundation
import Testing
@testable import ModuCore

struct AppUpdateTests {
    @Test func releaseSelectionUsesNumericVersionsAndOnlyOffersStableUpgrades() throws {
        let service = AppUpdateService()
        let data = try release(version: "1.10.0")
        #expect(try service.update(from: data, currentVersion: "1.9.0")?.version == "1.10.0")
        #expect(try service.update(from: data, currentVersion: "1.10") == nil)
        #expect(try service.update(from: data, currentVersion: "2.0.0") == nil)
        #expect(try service.update(from: release(version: "2.0.0", draft: true), currentVersion: "1.0.0") == nil)
        #expect(try service.update(from: release(version: "2.0.0", prerelease: true), currentVersion: "1.0.0") == nil)
    }

    @Test func incompatibleOrUntrustedInstallersAreRejected() throws {
        let service = AppUpdateService()
        for data in [
            try release(version: "2.0.0", filename: "Modu-2.0.0-x86_64.dmg"),
            try release(version: "2.0.0", downloadURL: "http://github.com/qimaotech/modu-desktop/releases/download/v2.0.0/Modu-2.0.0-arm64.dmg"),
            try release(version: "2.0.0", downloadURL: "https://github.com/other/repo/releases/download/v2.0.0/Modu-2.0.0-arm64.dmg"),
            try release(version: "2.0.0", downloadURL: "https://example.com/Modu-2.0.0-arm64.dmg"),
            try release(version: "2.0.0", filename: "../../Modu.app"),
            try release(version: "2.0.0-beta.1")
        ] {
            #expect(throws: ModuError.self) { try service.update(from: data, currentVersion: "1.0.0") }
        }
    }

    @Test func downloadVerificationRejectsTruncationAndTampering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("installer.dmg")
        let service = AppUpdateService()
        let digest = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let update = try #require(try service.update(from: release(version: "2.0.0", size: 3, digest: digest), currentVersion: "1.0.0"))
        try Data("abc".utf8).write(to: file)
        try service.verifyDownload(at: file, asset: update.asset)
        try Data("ab".utf8).write(to: file)
        #expect(throws: ModuError.self) { try service.verifyDownload(at: file, asset: update.asset) }
        try Data("abd".utf8).write(to: file)
        #expect(throws: ModuError.self) { try service.verifyDownload(at: file, asset: update.asset) }
        let legacy = try #require(try service.update(from: release(version: "2.0.0", size: 3), currentVersion: "1.0.0"))
        try service.verifyDownload(at: file, asset: legacy.asset)
        let invalid = try #require(try service.update(from: release(version: "2.0.0", size: 3, digest: "sha512:invalid"), currentVersion: "1.0.0"))
        #expect(throws: ModuError.self) { try service.verifyDownload(at: file, asset: invalid.asset) }
    }

    @Test func cachedDownloadsAreIsolatedAndCleanupPreservesOtherFiles() throws {
        let directory = TestEnvironment.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appending(path: "Caches/Updates")
        let service = AppUpdateService(cacheDirectory: cache)
        let update = try #require(try service.update(from: release(version: "2.0.0", size: 3), currentVersion: "1.0.0"))
        let temporary = directory.appending(path: "download")
        try Data("abc".utf8).write(to: temporary)
        let first = try service.cacheDownload(at: temporary, asset: update.asset)
        try Data("abc".utf8).write(to: temporary)
        let second = try service.cacheDownload(at: temporary, asset: update.asset)
        #expect(first != second && first.lastPathComponent == update.asset.name)
        #expect(first.deletingLastPathComponent().deletingLastPathComponent().path == cache.path)
        #expect(try Data(contentsOf: first) == Data("abc".utf8))
        #expect(!PathSafety.exists(temporary))

        let manual = directory.appending(path: UUID().uuidString).appending(path: update.asset.name)
        try FileManager.default.createDirectory(at: manual.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("manual download".utf8).write(to: manual)
        service.discardDownload(at: manual)
        service.discardDownload(at: cache.appending(path: update.asset.name))
        service.discardDownload(at: first)
        service.discardDownload(at: first)
        #expect(!PathSafety.exists(first.deletingLastPathComponent()))
        #expect(try Data(contentsOf: manual) == Data("manual download".utf8))
        #expect(try Data(contentsOf: second) == Data("abc".utf8))
        service.discardDownload(at: second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)

        try Data("incomplete".utf8).write(to: temporary)
        #expect(throws: ModuError.self) { try service.cacheDownload(at: temporary, asset: update.asset) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }

    private func release(version: String, draft: Bool = false, prerelease: Bool = false, filename: String? = nil,
                         downloadURL: String? = nil, size: Int = 3, digest: String? = nil) throws -> Data {
        let name = filename ?? "Modu-\(version)-arm64.dmg"
        var asset: [String: Any] = ["name": name, "size": size,
                                    "browser_download_url": downloadURL ?? "https://github.com/qimaotech/modu-desktop/releases/download/v\(version)/\(name)"]
        if let digest { asset["digest"] = digest }
        return try JSONSerialization.data(withJSONObject: ["tag_name": "v\(version)", "draft": draft, "prerelease": prerelease,
                                                          "html_url": "https://github.com/qimaotech/modu-desktop/releases/tag/v\(version)",
                                                          "assets": [asset]])
    }
}
