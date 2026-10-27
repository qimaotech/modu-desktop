import Foundation
import Darwin

public enum PathSafety {
    public static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    public static func confined(_ url: URL, to directory: URL) throws {
        try self.directory(directory)
        if exists(url), try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ModuError("unsafe-path", .symbolicLinksAreNotAllowedInTemporaryPath(url.path))
        }
        let path = canonical(url).path
        let prefix = directory.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else {
            throw ModuError("unsafe-path", .choosePathInsideTemporaryDirectory(directory.path))
        }
        // A missing leaf can prevent URL normalization from resolving its parent symlinks.
        var current = directory
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            current.append(path: String(component))
            if exists(current), try FileManager.default.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ModuError("unsafe-path", .symbolicLinksAreNotAllowedInTemporaryPath(current.path))
            }
        }
    }
    public static func identity(_ url: URL) -> String {
        let resolved = canonical(url)
        var volume = resolved
        while !FileManager.default.fileExists(atPath: volume.path), volume.path != "/" { volume.deleteLastPathComponent() }
        let sensitive = (try? volume.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
        let path = resolved.path.precomposedStringWithCanonicalMapping
        return sensitive ? path : path.lowercased()
    }
    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        return errno != ENOENT && errno != ENOTDIR
    }
    public static func directory(_ url: URL, allowMissing: Bool = false) throws {
        if !exists(url), allowMissing { return }
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeDirectory else { throw ModuError("unsafe-path", .expectedRealDirectory(url.path)) }
    }
    public static func child(_ relative: String, of root: URL, allowMissing: Bool = true) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else { throw ModuError("unsafe-path", .invalidResourcePath) }
        var current = canonical(root)
        for part in relative.split(separator: "/") {
            current.append(path: String(part))
            if exists(current) { try directory(current) }
            else if !allowMissing { throw ModuError("resource-missing", .directoryMissing(current.path)) }
        }
        return current
    }
    public static func emptyResourceDirectories(_ root: URL) throws {
        for name in ["repositories", "worktrees"] {
            let url = root.appending(path: name)
            try directory(url, allowMissing: true)
            if exists(url), try !FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty {
                throw ModuError("workspace-not-empty", .chooseFolderWithEmptyRepositoriesAndWorktrees(url.path))
            }
        }
    }
    public static func groupName(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-"), value != ".", value != "..", !value.contains("/"), !value.contains(":"), !value.contains("\0"), !value.hasPrefix("."), !value.hasSuffix("."), !value.hasSuffix(".lock"), !value.contains(".."), !value.contains("@{"), value.range(of: #"[\x00-\x20\x7f~^:?*\[\\]"#, options: .regularExpression) == nil else {
            throw ModuError("invalid-input", .groupNameMustBeOneDirectoryNameAnd)
        }
    }
    public static func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        do { try FileManager.default.trashItem(at: url, resultingItemURL: &result) }
        catch { throw ModuError("trash-failed", .couldNotMoveTrash(url.path, ModuError.wrap(error).userMessage)) }
        guard let result else { throw ModuError("trash-failed", .trashCompletedWithoutVerifiableDestination(url.path)) }
        return result as URL
    }
}
