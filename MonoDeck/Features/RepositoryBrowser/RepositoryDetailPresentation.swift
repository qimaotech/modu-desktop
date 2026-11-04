import AppKit
import MonoDeckCore

@MainActor final class RepositoryDetailPresentation {
    struct CommitRow: Identifiable {
        let commit: GitCommit
        let date: String
        var id: String { commit.id }
    }

    struct Commits {
        let rows: [CommitRow]
        let authorWidth: CGFloat
        let dateWidth: CGFloat
        let hashWidth: CGFloat
    }

    private let diagnostics: RepositoryReadDiagnostics?
    private var changes: [FileChange]?
    private var tree: [ChangeNode] = []
    private var collapsed: Set<String>?
    private var rows: [ChangeNode.Row] = []
    private var commits: [GitCommit]?
    private var locale: AppLocale?
    private var timeZone: String?
    private var fonts: [String] = []
    private var commitPresentation = Commits(rows: [], authorWidth: 0, dateWidth: 0, hashWidth: 0)

    init(diagnostics: RepositoryReadDiagnostics? = nil) { self.diagnostics = diagnostics }

    func changeRows(_ changes: [FileChange], collapsed: Set<String>) -> [ChangeNode.Row] {
        let changed = self.changes != changes
        if changed {
            let started = ContinuousClock.now
            self.changes = changes
            tree = ChangeNode.tree(changes)
            diagnostics?.record("presentation.change-tree", duration: started.duration(to: .now))
        }
        if changed || self.collapsed != collapsed {
            self.collapsed = collapsed
            rows = tree.flatMap { $0.visibleRows(collapsed: collapsed) }
            diagnostics?.record("presentation.change-rows")
        }
        return rows
    }

    func commitRows(_ commits: [GitCommit], locale: AppLocale, timeZone: TimeZone = .current,
                    font: NSFont = .systemFont(ofSize: 12), hashFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)) -> Commits {
        let fonts = [font.fontName, "\(font.pointSize)", hashFont.fontName, "\(hashFont.pointSize)"]
        guard self.commits != commits || self.locale != locale || self.timeZone != timeZone.identifier || self.fonts != fonts else { return commitPresentation }
        let started = ContinuousClock.now
        self.commits = commits; self.locale = locale; self.timeZone = timeZone.identifier; self.fonts = fonts
        let rows = commits.map { CommitRow(commit: $0, date: $0.displayDate(locale: locale, timeZone: timeZone)) }
        var author: CGFloat = 0, date: CGFloat = 0, hash: CGFloat = 0
        for row in rows {
            author = max(author, ceil((row.commit.author as NSString).size(withAttributes: [.font: font]).width))
            date = max(date, ceil((row.date as NSString).size(withAttributes: [.font: font]).width))
            hash = max(hash, ceil((String(row.id.prefix(7)) as NSString).size(withAttributes: [.font: hashFont]).width))
        }
        commitPresentation = Commits(rows: rows, authorWidth: author, dateWidth: date, hashWidth: hash)
        diagnostics?.record("presentation.commit-columns", duration: started.duration(to: .now))
        return commitPresentation
    }
}
