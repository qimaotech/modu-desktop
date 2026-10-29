import Foundation
import Darwin

struct PreparedRepository: Sendable {
    let repository: Repository
    let staging: RepositoryStaging
    let directory: RepositoryDirectory
}

enum RepositoryPreparation: Sendable {
    case ready(PreparedRepository)
    case failed(ItemResult)
}

enum RepositoryAdditionStart: Sendable {
    case finished(ItemResult)
    case prepare(RepositoryStaging)
}

struct RepositoryStaging: Sendable {
    let workspace: RepositoryDirectory
    let directory: RepositoryDirectory

    init(at root: URL) throws {
        workspace = try RepositoryDirectory(root)
        let parent = try PathSafety.child("repositories", of: root)
        if !PathSafety.exists(parent) { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false) }
        let url = parent.appending(path: ".modu-clone-\(UUID().uuidString)")
        guard mkdir(url.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        directory = try RepositoryDirectory(url)
    }

    func validate() throws {
        try workspace.validate()
        _ = try PathSafety.child("repositories/\(directory.url.lastPathComponent)", of: workspace.url, allowMissing: false)
        try directory.validate()
    }

    func makeDirectory(_ name: String) throws -> RepositoryDirectory {
        try validate()
        let url = try PathSafety.child(name, of: directory.url)
        guard mkdir(url.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try RepositoryDirectory(url)
    }

    func removeEmptyContainer() throws {
        try validate()
        // rmdir refuses nonempty containers, including data retained after failed cleanup.
        guard rmdir(directory.url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

struct RepositoryDirectory: Sendable {
    let url: URL
    private let values: URLResourceValues

    init(_ url: URL) throws {
        self.url = url
        values = try Self.values(at: url)
        guard values.fileResourceIdentifier != nil else { throw ModuError("unsafe-path", "Could not identify the repository preparation directory: \(url.path)") }
    }

    func validate() throws {
        let current = try Self.values(at: url)
        guard let expected = values.fileResourceIdentifier, let actual = current.fileResourceIdentifier, expected.isEqual(actual) else {
            throw ModuError("unsafe-path", "The repository preparation directory changed and was kept: \(url.path)")
        }
    }

    func relocated(to target: URL) -> RepositoryDirectory {
        RepositoryDirectory(url: target, values: values)
    }

    private init(url: URL, values: URLResourceValues) { self.url = url; self.values = values }

    private static func values(at url: URL) throws -> URLResourceValues {
        try PathSafety.directory(url)
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ModuError("unsafe-path", .expectedRealDirectory(url.path)) }
        return values
    }
}
