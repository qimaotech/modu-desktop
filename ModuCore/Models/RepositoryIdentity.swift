import Foundation

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
