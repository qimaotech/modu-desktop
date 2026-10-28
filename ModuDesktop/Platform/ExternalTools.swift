import Foundation
import AppKit
import ModuCore

public struct ExternalTool: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var category: String
    public var bundleID: String?
    public var icon: String
    public static let builtIn: [ExternalTool] = [
        .init(id: "fork", name: "Fork", category: "Git GUI", bundleID: "com.DanPristupov.Fork", icon: "Fork"),
        .init(id: "github-desktop", name: "GitHub Desktop", category: "Git GUI", bundleID: "com.github.GitHubClient", icon: "GitHubDesktop"),
        .init(id: "warp", name: "Warp", category: "Terminal", bundleID: "dev.warp.Warp-Stable", icon: "Warp"),
        .init(id: "iterm2", name: "iTerm2", category: "Terminal", bundleID: "com.googlecode.iterm2", icon: "iTerm2"),
        .init(id: "terminal", name: "Terminal", category: "Terminal", bundleID: "com.apple.Terminal", icon: "Terminal"),
        .init(id: "vscode", name: "VS Code", category: "Editor", bundleID: "com.microsoft.VSCode", icon: "VSCode"),
        .init(id: "cursor", name: "Cursor", category: "Editor", bundleID: "com.todesktop.230313mzl4w4u92", icon: "Cursor"),
        .init(id: "xcode", name: "Xcode", category: "Editor", bundleID: "com.apple.dt.Xcode", icon: "Xcode"),
        .init(id: "codex", name: "Codex", category: "Agent", bundleID: "com.openai.codex", icon: "Codex"),
        .init(id: "claude", name: "Claude Code", category: "Agent", bundleID: "com.anthropic.claudefordesktop", icon: "ClaudeCode")
    ]
}

@MainActor
public final class ExternalTools {
    private let git: Git
    private let applicationURL: (String) -> URL?
    private let openURL: (URL, URL) async throws -> Void

    public convenience init(git: Git = .init()) {
        self.init(git: git, applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }, openURL: { url, application in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
        })
    }
    init(git: Git = .init(), applicationURL: @escaping (String) -> URL?, openURL: @escaping (URL, URL) async throws -> Void) {
        self.git = git; self.applicationURL = applicationURL; self.openURL = openURL
    }
    public func available() async -> [ExternalTool] {
        ExternalTool.builtIn.filter { tool in tool.bundleID.map { applicationURL($0) != nil } ?? false }
    }
    public func open(_ tool: ExternalTool, directory: URL) async throws {
        try PathSafety.directory(directory)
        if tool.category == "Git GUI" { try await git.checkRepository(directory) }
        guard let id = tool.bundleID, let application = applicationURL(id) else { throw ModuError("tool-unavailable", .isNotInstalled("\(tool.name)")) }
        var target = directory
        if tool.id == "xcode" { target = try xcodeTarget(directory) }
        else if tool.id == "claude" {
            var link = URLComponents()
            link.scheme = "claude"; link.host = "code"; link.path = "/new"
            link.queryItems = [URLQueryItem(name: "folder", value: directory.path)]
            // Desktop uses form-style query decoding, where a literal + becomes a space.
            link.percentEncodedQuery = link.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = link.url else { throw ModuError("tool-launch-failed", .couldNotCreateClaudeCodeDesktopLink) }
            target = url
        }
        try await openURL(target, application)
    }

    private func xcodeTarget(_ directory: URL) throws -> URL {
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for fileExtension in ["xcworkspace", "xcodeproj"] {
            let projects = children.filter { $0.pathExtension == fileExtension && (try? FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeDirectory }
            if !projects.isEmpty { return projects.count == 1 ? projects[0] : directory }
        }
        let manifest = directory.appending(path: "Package.swift")
        if (try? FileManager.default.attributesOfItem(atPath: manifest.path)[.type] as? FileAttributeType) == .typeRegular { return manifest }
        return directory
    }
}
