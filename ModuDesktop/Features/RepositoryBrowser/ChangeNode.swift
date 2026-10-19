import Foundation
import ModuCore

struct ChangeNode: Identifiable {
    var id: String
    var name: String
    var change: FileChange?
    var children: [ChangeNode]?
    struct Row: Identifiable {
        let node: ChangeNode
        let depth: Int
        var id: String { node.id }
    }
    func visibleRows(collapsed: Set<String>, depth: Int = 0) -> [Row] {
        [Row(node: self, depth: depth)] + (collapsed.contains(id) ? [] : children?.flatMap { $0.visibleRows(collapsed: collapsed, depth: depth + 1) } ?? [])
    }
    static func tree(_ changes: [FileChange], prefix: String = "") -> [ChangeNode] {
        let grouped = Dictionary(grouping: changes) { change in
            let relative = change.path.dropFirst(prefix.count)
            guard let separator = relative.firstIndex(of: "/"), separator != relative.index(before: relative.endIndex) else { return String(relative) }
            return String(relative[..<separator])
        }
        return grouped.keys.map { name -> ChangeNode in
            let path = prefix + name, values = grouped[name]!
            if let leaf = values.first(where: { $0.path == path }) { return .init(id: path, name: name, change: leaf, children: values.count > 1 ? tree(values.filter { $0.path != path }, prefix: path + "/") : nil) }
            return .init(id: path, name: name, children: tree(values, prefix: path + "/"))
        }.sorted {
            if ($0.children != nil) != ($1.children != nil) { return $0.children != nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
