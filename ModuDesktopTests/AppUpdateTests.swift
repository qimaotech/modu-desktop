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

    @Test func downloadReportsProgressWithoutContentLengthAndThenVerifies() async throws {
        let cache = TestEnvironment.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let session = downloadSession()
        defer { session.invalidateAndCancel() }
        let service = AppUpdateService(session: session, cacheDirectory: cache)
        let update = try #require(try service.update(from: release(version: "2.0.0", size: DownloadProtocol.chunk.count * 2), currentVersion: "1.0.0"))
        let progress = DownloadProgressRecorder()

        let url = try await service.download(update, progress: progress.record)

        #expect(try Data(contentsOf: url) == DownloadProtocol.chunk + DownloadProtocol.chunk)
        #expect(progress.values.contains {
            if case let .downloading(received, total) = $0 { return received > 0 && received < total && total == update.asset.size }
            return false
        }, "\(progress.values)")
        guard case .verifying = progress.values.last else { Issue.record("Missing verification phase"); return }
        service.discardDownload(at: url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }

    @Test func cancelledDownloadDoesNotVerifyOrCacheAnIncompleteInstaller() async throws {
        let cache = TestEnvironment.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let session = downloadSession(hold: true)
        defer { session.invalidateAndCancel() }
        let service = AppUpdateService(session: session, cacheDirectory: cache)
        let update = try #require(try service.update(from: release(version: "2.0.0", size: DownloadProtocol.chunk.count * 2), currentVersion: "1.0.0"))
        let progress = DownloadProgressRecorder()
        let download = Task { try await service.download(update, progress: progress.record) }
        defer { download.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while progress.values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!progress.values.isEmpty)
        download.cancel()

        do {
            _ = try await download.value
            Issue.record("Cancelled download succeeded")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        #expect(!PathSafety.exists(cache))
        #expect(!progress.values.contains { if case .verifying = $0 { return true }; return false })
    }

    @Test func interruptedDownloadReportsTheFailureWithoutVerifyingOrCaching() async throws {
        let cache = TestEnvironment.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let session = downloadSession(fail: true)
        defer { session.invalidateAndCancel() }
        let service = AppUpdateService(session: session, cacheDirectory: cache)
        let update = try #require(try service.update(from: release(version: "2.0.0", size: DownloadProtocol.chunk.count * 2), currentVersion: "1.0.0"))
        let progress = DownloadProgressRecorder()

        do {
            _ = try await service.download(update, progress: progress.record)
            Issue.record("Interrupted download succeeded")
        } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        }
        #expect(!PathSafety.exists(cache))
        #expect(!progress.values.contains { if case .verifying = $0 { return true }; return false })
    }

    private func downloadSession(hold: Bool = false, fail: Bool = false) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Modu-Test-Hold": String(hold), "X-Modu-Test-Fail": String(fail)]
        return URLSession(configuration: configuration)
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

private final class DownloadProtocol: URLProtocol, @unchecked Sendable {
    static let chunk = Data(repeating: 42, count: 65_536)
    private let queue = DispatchQueue(label: "ModuTests.UpdateDownload")
    private var completion: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        queue.async { [self] in
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.chunk)
            guard request.value(forHTTPHeaderField: "X-Modu-Test-Hold") != "true" else { return }
            let completion = DispatchWorkItem { [self] in
                if request.value(forHTTPHeaderField: "X-Modu-Test-Fail") == "true" {
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                    return
                }
                client?.urlProtocol(self, didLoad: Self.chunk)
                client?.urlProtocolDidFinishLoading(self)
            }
            self.completion = completion
            queue.asyncAfter(deadline: .now() + 0.5, execute: completion)
        }
    }

    override func stopLoading() {
        queue.async { [self] in completion?.cancel(); completion = nil }
    }
}

private final class DownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AppUpdateDownloadProgress] = []
    var values: [AppUpdateDownloadProgress] { lock.withLock { recorded } }
    func record(_ progress: AppUpdateDownloadProgress) { lock.withLock { recorded.append(progress) } }
}
