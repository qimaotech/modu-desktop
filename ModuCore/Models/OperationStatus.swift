public enum OperationStatus: String, Codable, Sendable, CustomStringConvertible {
    case success, failed, skipped, cancelled
    case partialSuccess = "partial-success"
    case confirmationRequired = "confirmation-required"

    public var description: String { rawValue }
}

public enum OperationPhase: String, Codable, Sendable, CustomStringConvertible {
    case openingWorkspace = "Opening workspace…"
    case checkingRepository = "Checking repository…"
    case cloning = "Cloning…"
    case saving = "Saving…"
    case cleaningUp = "Cleaning up…"
    case updatingRepositories = "Updating repositories…"
    case importingRepositories = "Importing repositories…"
    case scanningRepositories = "Scanning local repositories…"
    case creatingWorkspaceWorktree = "Creating workspace worktree…"
    case creating = "Creating…"
    case deleting = "Deleting…"
    case added = "Added"
    case created = "Created"
    case deleted = "Deleted"

    public var description: String { rawValue }
}
