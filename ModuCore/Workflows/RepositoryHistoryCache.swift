import Foundation
import CryptoKit
import Darwin

extension WorkspaceService {
    public func historyCacheState(_ context: ResourceReadContext, session: ResourceReadSession? = nil) async throws -> RepositoryHistoryCacheState {
        try store.checkBoundary(context.workspace.rootURL)
        guard context.isValid(in: context.workspace) else { throw ModuError("resource-unavailable", .repositorySummaryIsUnavailable) }
        try Task.checkCancellation()
        let reader = inspectionService()
        let environment = reader.git.runner.environment
        let shallowPath = environment["GIT_SHALLOW_FILE"].map { URL(fileURLWithPath: $0, relativeTo: context.path) }
            ?? context.commonDirectory.appending(path: "shallow")
        let graftsPath = environment["GIT_GRAFT_FILE"].map { URL(fileURLWithPath: $0, relativeTo: context.path) }
            ?? context.commonDirectory.appending(path: "info/grafts")
        let shallow = try historyFileState(shallowPath)
        let grafts = try historyFileState(graftsPath)
        let prefix = reader.git.runner.environment["GIT_REPLACE_REF_BASE"] ?? "refs/replace/"
        let replacements: Data
        if try await replacementQueryIsNeeded(prefix: prefix, commonDirectory: context.commonDirectory, session: session) {
            let arguments = ["for-each-ref", "--format=%(refname) %(objectname)", "--"] + (prefix.hasSuffix("/") ? [prefix] : [])
            let output = try await reader.git.run(arguments, at: context.path).stdout
            if prefix.hasSuffix("/") { replacements = output }
            else {
                // Git concatenates a custom replacement base and OID without inserting a slash.
                let matching = String(decoding: output, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix(prefix) }
                replacements = Data(matching.joined(separator: "\n").utf8)
            }
        } else { replacements = Data() }
        try Task.checkCancellation()
        let bytes = Data((shallow.fingerprint + "\n" + grafts.fingerprint + "\n").utf8) + replacements
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(reusable: !shallow.exists && !grafts.exists && replacements.isEmpty, fingerprint: fingerprint)
    }

    private func replacementQueryIsNeeded(prefix: String, commonDirectory: URL, session: ResourceReadSession?) async throws -> Bool {
        if PathSafety.exists(commonDirectory.appending(path: "reftable")) { return true }
        let components = prefix.split(separator: "/", omittingEmptySubsequences: false)
        guard prefix.hasPrefix("refs/"), prefix.hasSuffix("/"), !prefix.contains("\0"),
              components.dropLast(prefix.hasSuffix("/") ? 1 : 0).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return true }
        if PathSafety.exists(commonDirectory.appending(path: prefix)) { return true }
        let packed = commonDirectory.appending(path: "packed-refs")
        guard PathSafety.exists(packed) else { return false }
        let before = try historyFileState(packed)
        if let cached = await session?.cachedReplacementDecision(for: commonDirectory, namespace: prefix, fingerprint: before.fingerprint) {
            return before == (try historyFileState(packed)) ? cached : true
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: packed.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 8 * 1_024 * 1_024 else { return true }
        let bytes = try Data(contentsOf: packed)
        let needed = bytes.range(of: Data((" " + prefix).utf8)) != nil
        guard before == (try historyFileState(packed)) else { return true }
        try Task.checkCancellation()
        await session?.cacheReplacementDecision(needed, for: commonDirectory, namespace: prefix, fingerprint: before.fingerprint)
        return needed
    }

    private func historyFileState(_ path: URL) throws -> (exists: Bool, fingerprint: String) {
        var metadata = stat()
        guard lstat(path.path, &metadata) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return (false, "missing") }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        // Special graph modes are never reused, but their identity still detects changes during a read.
        let fingerprint = "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_size):\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec):\(metadata.st_ctimespec.tv_sec):\(metadata.st_ctimespec.tv_nsec)"
        return (true, fingerprint)
    }
}
