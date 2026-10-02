import Foundation
import Darwin

public struct RepositoryIdentity: Sendable {
    public let name: String
    public init(_ raw: String) throws {
        let fail = ModuError("invalid-input", "Use an HTTPS, SSH, or SCP-style Git URL without embedded credentials.")
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines), !raw.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue == 0 }) else { throw fail }
        let path: String
        if raw.contains("://") {
            guard let c = URLComponents(string: raw), ["https", "ssh"].contains(c.scheme?.lowercased() ?? ""),
                  let host = c.host, !host.isEmpty, c.password == nil,
                  c.scheme?.lowercased() != "https" || c.user == nil,
                  c.query == nil || !Self.sensitiveQuery(c.query!) else { throw fail }
            path = c.percentEncodedPath.removingPercentEncoding ?? c.path
        } else {
            guard let colon = raw.firstIndex(of: ":"), !raw[..<colon].contains("/"), !raw.hasPrefix("-"),
                  raw[..<colon].contains("@"), !raw[raw.index(after: colon)...].isEmpty else { throw fail }
            let host = raw[..<colon].split(separator: "@", omittingEmptySubsequences: false)
            guard host.count == 2, !host[0].isEmpty, !host[1].isEmpty else { throw fail }
            path = String(raw[raw.index(after: colon)...]).components(separatedBy: "?")[0].components(separatedBy: "#")[0]
        }
        var n = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        if n.hasSuffix(".git") { n.removeLast(4) }
        guard n.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil, n != ".", n != ".." else { throw fail }
        name = n
    }
    private static func sensitiveQuery(_ query: String) -> Bool {
        query.lowercased().contains("token") || query.lowercased().contains("password") || query.lowercased().contains("secret") || query.lowercased().contains("authorization")
    }
}

public enum PathSafety {
    public static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
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
        guard a[.type] as? FileAttributeType == .typeDirectory else { throw ModuError("unsafe-path", "Expected a real directory: \(url.path)") }
    }
    public static func child(_ relative: String, of root: URL, allowMissing: Bool = true) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else { throw ModuError("unsafe-path", "Invalid resource path.") }
        var current = canonical(root)
        for part in relative.split(separator: "/") {
            current.append(path: String(part))
            if exists(current) { try directory(current) }
            else if !allowMissing { throw ModuError("resource-missing", "Directory missing: \(current.path)") }
        }
        return current
    }
    public static func emptyResourceDirectories(_ root: URL) throws {
        for name in ["repositories", "worktrees"] {
            let url = root.appending(path: name)
            try directory(url, allowMissing: true)
            if exists(url), try !FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty {
                throw ModuError("workspace-not-empty", "Choose a folder with empty repositories/ and worktrees/: \(url.path)")
            }
        }
    }
    public static func groupName(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-"), value != ".", value != "..", !value.contains("/"), !value.contains(":"), !value.contains("\0"), !value.hasPrefix("."), !value.hasSuffix("."), !value.hasSuffix(".lock"), !value.contains(".."), !value.contains("@{"), value.range(of: #"[\x00-\x20\x7f~^:?*\[\\]"#, options: .regularExpression) == nil else {
            throw ModuError("invalid-input", "Group name must be one directory name and a valid Git branch name.")
        }
    }
    public static func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        do { try FileManager.default.trashItem(at: url, resultingItemURL: &result) }
        catch { throw ModuError("trash-failed", "Could not move to Trash: \(url.path). \(error.localizedDescription)") }
        guard let result else { throw ModuError("trash-failed", "Trash completed without a verifiable destination: \(url.path)") }
        return result as URL
    }
}
