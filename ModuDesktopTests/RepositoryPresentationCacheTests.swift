import AppKit
import Testing
@testable import ModuCore
@testable import ModuDesktop

@MainActor struct RepositoryPresentationCacheTests {
    @Test func unchangedContentAndFoldingReuseTheTree() {
        let counts = PresentationCounts()
        let cache = RepositoryDetailPresentation(diagnostics: .init { counts.record($0.name) })
        let changes = [FileChange(path: "Sources/main.swift", index: " ", workingTree: "M")]
        let expanded = cache.changeRows(changes, collapsed: [])
        #expect(expanded.map(\.id) == ["Sources", "Sources/main.swift"])
        _ = cache.changeRows(changes, collapsed: [])
        #expect(counts.count("presentation.change-tree") == 1 && counts.count("presentation.change-rows") == 1)
        #expect(cache.changeRows(changes, collapsed: ["Sources"]).map(\.id) == ["Sources"])
        #expect(counts.count("presentation.change-tree") == 1 && counts.count("presentation.change-rows") == 2)
        _ = cache.changeRows(changes + [.init(path: "new.txt", index: " ", workingTree: "?")], collapsed: [])
        #expect(counts.count("presentation.change-tree") == 2)
    }

    @Test func datesAndWidthsOnlyChangeWithContentLocaleOrFont() {
        let counts = PresentationCounts()
        let cache = RepositoryDetailPresentation(diagnostics: .init { counts.record($0.name) })
        let commits = [GitCommit(id: String(repeating: "a", count: 40), subject: "Subject", author: "Author", date: "2026-11-02T00:00:00Z")]
        _ = cache.commitRows(commits, locale: .english)
        _ = cache.commitRows(commits, locale: .english)
        #expect(counts.count("presentation.commit-columns") == 1)
        _ = cache.commitRows(commits, locale: .simplifiedChinese)
        #expect(counts.count("presentation.commit-columns") == 2)
        _ = cache.commitRows(commits, locale: .simplifiedChinese, font: .systemFont(ofSize: 16))
        #expect(counts.count("presentation.commit-columns") == 3)
    }
}

private final class PresentationCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }
}
