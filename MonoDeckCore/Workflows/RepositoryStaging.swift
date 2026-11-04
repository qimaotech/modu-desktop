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
        let url = parent.appending(path: ".mono-deck-clone-\(UUID().uuidString)")
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
    private let identity: Identity

    init(_ url: URL) throws {
        self.url = url
        identity = try Identity(at: url)
    }

    func validate() throws {
        guard try Identity(at: url) == identity else {
            throw MonoDeckError("unsafe-path", "The repository preparation directory changed and was kept: \(url.path)")
        }
    }

    func relocated(to target: URL) -> RepositoryDirectory {
        RepositoryDirectory(url: target, identity: identity)
    }

    private init(url: URL, identity: Identity) { self.url = url; self.identity = identity }

    private struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t

        init(at url: URL) throws {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard metadata.st_mode & S_IFMT == S_IFDIR else { throw MonoDeckError("unsafe-path", .expectedRealDirectory(url.path)) }
            device = metadata.st_dev; inode = metadata.st_ino
        }
    }
}
