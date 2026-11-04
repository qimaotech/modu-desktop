import Foundation

extension Git {
    public func ignoredPaths(_ paths: [String], at directory: URL) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        guard paths.count <= ResourceChangeEvent.maximumCandidateCount,
              paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/").contains("..") }) else {
            throw MonoDeckError("invalid-input", "Invalid ignore-check paths.")
        }
        let input = Data((paths.joined(separator: "\0") + "\0").utf8)
        guard input.count <= ResourceChangeEvent.maximumCandidateBytes else { throw MonoDeckError("invalid-input", "Ignore-check input is too large.") }
        let output = try await run(["check-ignore", "--stdin", "-z"], at: directory, allowFailure: true, input: input)
        guard output.status == 0 || output.status == 1 else {
            throw MonoDeckError("git-failed", .gitFailed("check-ignore", Int(output.status), .diagnostic(Self.sanitize(String(decoding: output.stderr, as: UTF8.self)))))
        }
        let ignored = Set(output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        guard ignored.isSubset(of: Set(paths)) else { throw MonoDeckError("git-output-invalid", "Invalid ignore-check output.") }
        return ignored
    }
}
