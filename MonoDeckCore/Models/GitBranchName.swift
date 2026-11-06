import Foundation

public enum GitBranchName {
    public static func validate(_ value: String) throws {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.hasPrefix("-"), !value.hasSuffix("."),
              !value.contains(".."), !value.contains("@{"),
              value.range(of: #"[\x00-\x20\x7f~^:?*\[\\]"#, options: .regularExpression) == nil,
              components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }) else {
            throw MonoDeckError("invalid-input", .invalidGroupBranchName(value))
        }
    }
}
