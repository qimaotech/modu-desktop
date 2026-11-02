import Foundation

public struct RepositoryReadDiagnostics: Sendable {
    public struct Event: Sendable {
        public let name: String
        public let duration: Duration?
        public let count: Int
        public let bytes: Int

        public var milliseconds: Double? {
            duration.map { Double($0.components.seconds) * 1_000 + Double($0.components.attoseconds) / 1e15 }
        }
    }

    private let sink: @Sendable (Event) -> Void

    public init(_ sink: @escaping @Sendable (Event) -> Void) { self.sink = sink }

    public func record(_ name: String, duration: Duration? = nil, count: Int = 1, bytes: Int = 0) {
        sink(Event(name: name, duration: duration, count: count, bytes: bytes))
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard environment["MODU_READ_DIAGNOSTICS"] == "1" else { return nil }
        return Self { event in
            var record: [String: Any] = ["modu-read": event.name, "count": event.count, "bytes": event.bytes]
            if let elapsed = event.milliseconds { record["milliseconds"] = elapsed }
            if var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                data.append(10)
                FileHandle.standardError.write(data)
            }
        }
    }
}

extension WorkspaceService {
    public func withDiagnostics(_ diagnostics: RepositoryReadDiagnostics) -> WorkspaceService {
        var reader = git
        reader.runner.diagnostics = diagnostics
        return WorkspaceService(store: store, git: reader, trash: trashDirectory)
    }
}
