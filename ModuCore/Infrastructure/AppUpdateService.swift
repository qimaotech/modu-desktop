import CryptoKit
import Foundation

public struct AppUpdate: Sendable {
    public let version: String
    public let releaseURL: URL
    public let asset: Asset

    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int64
        public let browserDownloadURL: URL
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }
}

public struct AppUpdateService: Sendable {
    public static let releasesURL = URL(string: "https://github.com/qimaotech/modu-desktop/releases/latest")!
    private let session: URLSession
    private let cacheDirectory: URL

    public init(session: URLSession = .shared, cacheDirectory: URL? = nil) {
        self.session = session
        self.cacheDirectory = cacheDirectory ?? URL.cachesDirectory.appending(path: "fun.armantang.ModuDesktop/Updates", directoryHint: .isDirectory)
    }

    public func check(currentVersion: String = ModuVersion.current) async throws -> AppUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/qimaotech/modu-desktop/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Modu/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try validate(response)
        return try update(from: data, currentVersion: currentVersion)
    }

    public func download(_ update: AppUpdate) async throws -> URL {
        var request = URLRequest(url: update.asset.browserDownloadURL)
        request.timeoutInterval = 60
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try validate(response)
        return try cacheDownload(at: temporary, asset: update.asset)
    }

    public func discardDownload(at url: URL) {
        let directory = url.deletingLastPathComponent()
        guard PathSafety.canonical(directory.deletingLastPathComponent()).path == PathSafety.canonical(cacheDirectory).path,
              UUID(uuidString: directory.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    func cacheDownload(at temporary: URL, asset: AppUpdate.Asset) throws -> URL {
        try verifyDownload(at: temporary, asset: asset)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let directory = cacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let destination = directory.appendingPathComponent(asset.name)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try Task.checkCancellation()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func update(from data: Data, currentVersion: String) throws -> AppUpdate? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        let available = try versionComponents(version)
        let installed = try versionComponents(currentVersion)
        guard installed.lexicographicallyPrecedes(available) else { return nil }
        let filename = "Modu-\(version)-arm64.dmg"
        guard let asset = release.assets.first(where: { $0.name == filename }), asset.size > 0,
              asset.browserDownloadURL.scheme == "https", asset.browserDownloadURL.host == "github.com",
              asset.browserDownloadURL.path == "/qimaotech/modu-desktop/releases/download/\(release.tagName)/\(filename)",
              release.htmlURL.scheme == "https", release.htmlURL.host == "github.com",
              release.htmlURL.path == "/qimaotech/modu-desktop/releases/tag/\(release.tagName)" else {
            throw ModuError("update-asset-unavailable", .latestReleaseHasNoCompatibleModuInstaller)
        }
        return AppUpdate(version: version, releaseURL: release.htmlURL, asset: asset)
    }

    func verifyDownload(at url: URL, asset: AppUpdate.Asset) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard size?.int64Value == asset.size else {
            throw ModuError("update-integrity-failed", .downloadedInstallerIsIncompletePleaseTryAgain)
        }
        guard let digest = asset.digest else { return }
        let parts = digest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "sha256", parts[1].count == 64,
              parts[1].allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ModuError("update-integrity-failed", .releaseContainsUnsupportedInstallerChecksum)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == parts[1].lowercased() else {
            throw ModuError("update-integrity-failed", .installerChecksumDoesNotMatchPleaseTryAgain)
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ModuError("update-request-failed", .githubReturnedInvalidResponse)
        }
        guard http.statusCode == 200 else {
            throw ModuError("update-request-failed", .githubRequestFailedHTTPPleaseTryAgainLater(Int(http.statusCode)))
        }
    }

    private func versionComponents(_ version: String) throws -> [UInt64] {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else {
            throw ModuError("update-version-invalid", .releaseVersionCouldNotBeCompared)
        }
        let values = parts.compactMap { UInt64($0) }
        guard values.count == parts.count else { throw ModuError("update-version-invalid", .releaseVersionCouldNotBeCompared) }
        return values + Array(repeating: 0, count: 3 - values.count)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [AppUpdate.Asset]

        enum CodingKeys: String, CodingKey {
            case draft, prerelease, assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
