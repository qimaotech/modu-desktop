import Foundation

public struct Git: Sendable {
    public var runner: CommandRunner
    public init(runner: CommandRunner = .init()) {
        var runner = runner
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] { runner.environment.removeValue(forKey: key) }
        runner.environment["GIT_TERMINAL_PROMPT"] = "0"
        runner.environment["GCM_INTERACTIVE"] = "Never"
        runner.environment["GIT_ASKPASS"] = "/usr/bin/false"
        runner.environment["SSH_ASKPASS"] = "/usr/bin/false"
        // Reject prompts even with a TTY, while Git keeps its native SSH command precedence.
        runner.environment["SSH_ASKPASS_REQUIRE"] = "force"
        runner.environment["LC_ALL"] = "C"
        self.runner = runner
    }
    public func run(_ arguments: [String], at url: URL, timeout: TimeInterval = 60, allowFailure: Bool = false, cancellable: Bool = true) async throws -> CommandOutput {
        let output: CommandOutput
        do { output = try await runner.run("/usr/bin/git", arguments, at: url, timeout: timeout, cancellable: cancellable) }
        catch let error as ModuError {
            throw ModuError(error.code, .git(arguments.first ?? "command", error.userMessage))
        }
        if output.status != 0 && !allowFailure {
            let raw = String(decoding: output.stderr, as: UTF8.self)
            let auth = raw.localizedCaseInsensitiveContains("authentication") || raw.contains("Permission denied") || raw.contains("Host key verification")
            throw ModuError(auth ? "authentication-failed" : "git-failed", .gitFailed(arguments.first ?? "command", Int(output.status), .diagnostic(Self.sanitize(raw))))
        }
        return output
    }
    public static func sanitize(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: #"(?:https?|ssh)://[^\s\"']+"#, with: "[remote URL]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(token|password|authorization|secret)[=: ]+[^\s]+"#, with: "$1=[redacted]", options: .regularExpression)
        return String(clean.prefix(2000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
