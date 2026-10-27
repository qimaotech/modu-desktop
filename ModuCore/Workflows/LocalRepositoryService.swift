import Foundation

extension WorkspaceService {
    public func scanLocalRepositories(in directories: [URL], at root: URL, progress: ProgressHandler = { _ in }) async throws -> LocalRepositoryScan {
        try store.checkBoundary(root)
        var urls: [String] = []
        let selectedDirectories = directories.map(PathSafety.canonical)
        let selectedPaths = Set(selectedDirectories.map(PathSafety.identity))
        var pending = selectedDirectories.reversed().map { (directory: $0, recursive: true) }
        var visited = Set<String>(), seenURLs = Set<String>()
        var lastReport = ContinuousClock.now
        while let entry = pending.popLast() {
            try checkCancellation()
            let directory = entry.directory
            let identity = PathSafety.identity(directory)
            guard visited.insert(identity).inserted else { continue }
            let explicitlySelected = selectedPaths.contains(identity)
            if visited.count == 1 || lastReport.duration(to: .now) >= .milliseconds(100) {
                progress(.init(directory.path, .scanningRepositories))
                lastReport = .now
                try checkCancellation()
            }
            do {
                try store.checkBoundary(directory)
                try PathSafety.directory(directory)
                let hasGitFile = PathSafety.exists(directory.appending(path: ".git"))
                let looksBare = PathSafety.exists(directory.appending(path: "HEAD")) && PathSafety.exists(directory.appending(path: "objects")) && PathSafety.exists(directory.appending(path: "refs"))
                if hasGitFile || looksBare {
                    do {
                        if hasGitFile { try await git.checkRepository(directory) }
                        else {
                            let gitDirectory = try await git.run(["rev-parse", "--absolute-git-dir"], at: directory).text
                            guard PathSafety.identity(URL(fileURLWithPath: gitDirectory)) == PathSafety.identity(directory) else {
                                throw ModuError("resource-unavailable", .notRepositoryRoot)
                            }
                        }
                    } catch {
                        try checkCancellation()
                        continue
                    }
                    if let url = try await localRepositoryURL(at: directory), seenURLs.insert(url).inserted {
                        urls.append(url)
                    }
                    if !explicitlySelected { continue }
                }
                guard entry.recursive || explicitlySelected else { continue }
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
                let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
                for child in children.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                    try checkCancellation()
                    guard !Self.repositoryScanIgnoredDirectories.contains(child.lastPathComponent.lowercased()) else { continue }
                    do {
                        let values = try child.resourceValues(forKeys: keys)
                        if values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true {
                            pending.append((child, recursive: !hasGitFile && !looksBare))
                        }
                    } catch { continue }
                }
            } catch {
                try checkCancellation()
            }
        }
        try checkCancellation()
        let checkedURLs = try await checkedLocalRepositoryURLs(urls, at: root, progress: progress)
        return LocalRepositoryScan(urls: checkedURLs)
    }

    private func checkedLocalRepositoryURLs(_ urls: [String], at root: URL, progress: ProgressHandler) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        progress(.init(try RepositoryIdentity(urls[0]).name, .checkingRepository, total: urls.count))
        try checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            var available = Array(repeating: false, count: urls.count)
            var next = 0, completed = 0
            for index in 0..<min(8, urls.count) {
                guard group.addTaskUnlessCancelled(operation: {
                    (index, try await localRepositoryRemoteAvailable(urls[index], at: root))
                }) else { try checkCancellation(); break }
                next += 1
            }
            while let (index, valid) = try await group.next() {
                try checkCancellation()
                available[index] = valid
                completed += 1
                progress(.init(try RepositoryIdentity(urls[index]).name, .checkingRepository, completed: completed, total: urls.count))
                try checkCancellation()
                if next < urls.count {
                    let index = next
                    if group.addTaskUnlessCancelled(operation: {
                        (index, try await localRepositoryRemoteAvailable(urls[index], at: root))
                    }) { next += 1 }
                }
            }
            try checkCancellation()
            return urls.enumerated().compactMap { available[$0.offset] ? $0.element : nil }
        }
    }

    private func localRepositoryRemoteAvailable(_ url: String, at root: URL) async throws -> Bool {
        try checkCancellation()
        do {
            _ = try await remoteDefault(url, at: root)
            try checkCancellation()
            return true
        } catch {
            try checkCancellation()
            return false
        }
    }

    private func localRepositoryURL(at directory: URL) async throws -> String? {
        do {
            let configured = try await git.run(["config", "--null", "--get-regexp", #"^remote\."#], at: directory, allowFailure: true)
            guard configured.status == 0 else { return nil }
            var remotes = Set<String>(), urls: [String: String] = [:]
            for record in configured.stdout.split(separator: 0) {
                let fields = String(decoding: record, as: UTF8.self).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let key = fields[0].dropFirst("remote.".count)
                guard let separator = key.lastIndex(of: ".") else { continue }
                let name = String(key[..<separator])
                guard !name.isEmpty else { continue }
                remotes.insert(name)
                if key[separator...] == ".url", urls[name] == nil, fields.count == 2 { urls[name] = String(fields[1]) }
            }
            guard let remote = remotes.contains("origin") ? "origin" : (remotes.count == 1 ? remotes.first : nil),
                  var url = urls[remote] else { return nil }
            // Keep portable URLs; expand repository-local aliases only when the configured value is unsupported.
            if (try? RepositoryIdentity(url)) == nil {
                url = try await git.run(["remote", "get-url", "--", remote], at: directory).text
            }
            guard (try? RepositoryIdentity(url)) != nil else {
                return nil
            }
            return url
        } catch {
            try checkCancellation()
            return nil
        }
    }

    private static let repositoryScanIgnoredDirectories: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "bower_components", "dist", "build", ".build", "target", "out",
        ".next", ".nuxt", ".output", ".svelte-kit", ".angular", ".turbo", ".parcel-cache", "coverage",
        ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", ".cache", ".gradle", "deriveddata"
    ]
}
