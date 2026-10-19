import Foundation

public struct ModuError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
    public static func wrap(_ error: Error, code: String = "operation-failed") -> ModuError {
        error as? ModuError ?? ModuError(code, Git.sanitize(error.localizedDescription))
    }
}
