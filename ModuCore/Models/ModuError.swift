import Foundation

public struct ModuError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let userMessage: UserMessage
    public init(_ code: String, _ message: String, userMessage: UserMessage? = nil) { self.code = code; self.message = message; self.userMessage = userMessage ?? .diagnostic(message) }
    public init(_ code: String, _ userMessage: UserMessage) { self.code = code; self.userMessage = userMessage; message = userMessage.englishDescription }
    public var errorDescription: String? { message }
    public static func wrap(_ error: Error, code: String = "operation-failed") -> ModuError {
        error as? ModuError ?? ModuError(code, Git.sanitize(error.localizedDescription))
    }
}
