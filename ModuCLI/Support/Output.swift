import Foundation
import ModuCore
import Darwin

func reportProgress(_ value: OperationProgress) { diagnostic("\(value.target): \(value.phase)") }
func diagnostic(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
func confirm(_ targets: [DeletionTarget]) -> Bool {
    for target in targets { diagnostic("\(target.path)\n\(target.risks.joined(separator: "\n"))") }
    diagnostic("Permanently delete the listed worktrees and current local branches? [y/N]")
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
    if Task.isCancelled && result.status == .confirmationRequired { result.status = .cancelled; result.reasonCode = "cancelled" }
    if json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { let data = try encoder.encode(result); FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
        catch { diagnostic("Could not encode result."); exit(1) }
    } else {
        print("\(result.command): \(result.status)")
        if let message = result.message { print(message) }
        for item in result.items {
            print("\(item.resource.path): \(item.status)\(item.message.map { " — " + $0 } ?? "")")
            for effect in item.effects { print("  \(effect.action): \(effect.target) [\(effect.state)]") }
            if let trash = item.trashPath { print("  Trash: \(trash)") }
        }
        for target in result.plan ?? [] { print("\(target.path)\n\(target.risks.joined(separator: "\n"))") }
    }
    exit(result.exitCode)
}

func finish(_ tree: WorkspaceTreeNode, json: Bool) throws -> Never {
    let output: Data
    if json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var encoded = try encoder.encode(tree)
        encoded.append(10)
        output = encoded
    } else {
        var lines = [directoryLabel(tree.path)]
        appendTreeChildren(tree.children, prefix: "", to: &lines)
        output = Data((lines.joined(separator: "\n") + "\n").utf8)
    }
    guard !Task.isCancelled else { throw ModuError("cancelled", .operationCancelled) }
    FileHandle.standardOutput.write(output)
    exit(0)
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
