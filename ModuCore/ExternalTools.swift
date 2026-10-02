import Foundation
import AppKit

public struct ExternalTool: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var category: String
    public var bundleID: String?
    public var icon: String
    public static let builtIn: [ExternalTool] = [
        .init(id: "codex", name: "Codex", category: "Agent", bundleID: "com.openai.codex", icon: "Codex"),
        .init(id: "claude", name: "Claude Code", category: "Agent", bundleID: "com.anthropic.claudefordesktop", icon: "ClaudeCode"),
        .init(id: "fork", name: "Fork", category: "Git GUI", bundleID: "com.DanPristupov.Fork", icon: "Fork"),
        .init(id: "vscode", name: "VS Code", category: "Editor", bundleID: "com.microsoft.VSCode", icon: "VSCode"),
        .init(id: "cursor", name: "Cursor", category: "Editor", bundleID: "com.todesktop.230313mzl4w4u92", icon: "Cursor"),
        .init(id: "warp", name: "Warp", category: "Terminal", bundleID: "dev.warp.Warp-Stable", icon: "Warp"),
        .init(id: "terminal", name: "Terminal", category: "Terminal", bundleID: "com.apple.Terminal", icon: "Terminal")
    ]
}

@MainActor
public final class ExternalTools {
    private let applicationURL: (String) -> URL?
    private let openURL: (URL, URL) async throws -> Void

    public convenience init() {
        self.init(applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }, openURL: { url, application in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
        })
    }
    init(applicationURL: @escaping (String) -> URL?, openURL: @escaping (URL, URL) async throws -> Void) {
        self.applicationURL = applicationURL; self.openURL = openURL
    }
    public func available() async -> [ExternalTool] {
        ExternalTool.builtIn.filter { tool in tool.bundleID.map { applicationURL($0) != nil } ?? false }
    }
    public func open(_ tool: ExternalTool, directory: URL) async throws {
        try PathSafety.directory(directory)
        if tool.id == "fork" { try await Git().checkRepository(directory) }
        guard let id = tool.bundleID, let application = applicationURL(id) else { throw ModuError("tool-unavailable", "\(tool.name) is not installed.") }
        var target = directory
        if tool.id == "claude" {
            var link = URLComponents()
            link.scheme = "claude"; link.host = "code"; link.path = "/new"
            link.queryItems = [URLQueryItem(name: "folder", value: directory.path)]
            // Desktop uses form-style query decoding, where a literal + becomes a space.
            link.percentEncodedQuery = link.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = link.url else { throw ModuError("tool-launch-failed", "Could not create the Claude Code desktop link.") }
            target = url
        }
        try await openURL(target, application)
    }
}
