import Foundation
import MonoDeckCore
import Darwin

func reportProgress(_ value: OperationProgress) { diagnostic("\(value.target): \(value.phase)") }
func diagnostic(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
func confirm(_ targets: [DeletionTarget]) -> Bool {
    for target in targets { diagnostic("\(target.path)\n\(target.risks.joined(separator: "\n"))") }
    diagnostic("Apply the listed deletion plan? [y/N]")
    var input = Data()
    while !Task.isCancelled {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 100) > 0 {
            var byte: UInt8 = 0
            if read(STDIN_FILENO, &byte, 1) != 1 || byte == 10 { break }
            input.append(byte)
            if input.count > 32 { return false }
        }
    }
    return !Task.isCancelled && ["y", "yes"].contains(String(decoding: input, as: UTF8.self).lowercased())
}
func finish(_ value: OperationResult, json: Bool) -> Never {
    var result = value
    if Task.isCancelled && (result.status == .confirmationRequired || (result.status == .success && (result.dryRun || result.data != nil))) {
        result.status = .cancelled; result.reasonCode = "cancelled"; result.data = nil
    }
    if json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { let data = try encoder.encode(result); FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
        catch { diagnostic("Could not encode result."); exit(1) }
    } else if result.status == .success, let tree = result.data?.tree {
        var lines = [directoryLabel(tree.path)]
        appendTreeChildren(tree.children, prefix: "", to: &lines)
        print(lines.joined(separator: "\n"))
    } else {
        print("\(result.command): \(result.status)\(result.dryRun ? " (dry run)" : "")")
        if let message = result.message { print(message) }
        for item in result.items {
            print("\(item.resource.path): \(item.status)\(item.message.map { " — " + $0 } ?? "")")
            for effect in item.effects { print("  \(effect.action): \(effect.target) [\(effect.state)]") }
            if let trash = item.trashPath { print("  Trash: \(trash)") }
        }
        for action in result.plan?.actions ?? [] { print("  \(action.action): \(action.target) [planned]") }
        for target in result.plan?.deletions ?? [] { print("\(target.path)\n\(target.risks.joined(separator: "\n"))") }
    }
    exit(result.exitCode)
}

private func appendTreeChildren(_ children: [WorkspaceTreeNode]?, prefix: String, to lines: inout [String]) {
    guard let children else { return }
    for (index, child) in children.enumerated() {
        let last = index == children.count - 1
        lines.append(prefix + (last ? "`-- " : "|-- ") + directoryLabel(child.path))
        appendTreeChildren(child.children, prefix: prefix + (last ? "    " : "|   "), to: &lines)
    }
}

private func directoryLabel(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }
