import AppKit
import UniformTypeIdentifiers

@MainActor
enum FilePanels {
    static func directory(at directory: URL? = nil, prompt: String? = nil) async -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = directory
        if let prompt { panel.prompt = prompt }
        return await panel.begin() == .OK ? panel.url : nil
    }
    static func readYAML(prompt: String) async throws -> (name: String, text: String)? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "yaml")!, UTType(filenameExtension: "yml")!]; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = prompt
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        return (url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))
    }
    static func repositoryDirectories(prompt: String, message: String) async -> [URL]? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = prompt; panel.message = message
        return await panel.begin() == .OK ? panel.urls : nil
    }
    static func yamlDestination(name: String, directory: URL? = nil) async -> URL? {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "yaml")!]; panel.nameFieldStringValue = name + ".yaml"
        panel.directoryURL = directory
        return await panel.begin() == .OK ? panel.url : nil
    }
}
