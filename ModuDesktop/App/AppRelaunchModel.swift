import AppKit
import ModuCore
import Observation

@MainActor @Observable
final class AppRelaunchModel {
    private let relauncher: AppRelauncher
    private let application: URL
    private let helper: URL?
    private let arguments: [String]
    private let requestRestart: @MainActor () -> Void
    private var environment: [String: String] = [:]
    private var handoff: AppRelaunch?
    @ObservationIgnored private var handoffTask: Task<Void, Never>?
    @ObservationIgnored var onFailure: (@MainActor (Error) -> Void)?
    private(set) var restartPending = false

    init(relauncher: AppRelauncher = .init(), application: URL = Bundle.main.bundleURL,
         helper: URL? = Bundle.main.url(forResource: "modu-cli", withExtension: nil),
         arguments: [String] = Array(ProcessInfo.processInfo.arguments.dropFirst()),
         requestRestart: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.relauncher = relauncher
        self.application = application
        self.helper = helper
        self.arguments = arguments
        self.requestRestart = requestRestart
    }

    func restart(environment: [String: String] = [:]) {
        guard !restartPending else { return }
        self.environment = environment
        restartPending = true
        requestRestart()
    }

    func prepareToTerminate() async -> Bool {
        guard restartPending, handoff == nil else { return true }
        do {
            guard let helper else { throw ModuError("relaunch-failed", "The bundled relaunch helper is missing. Please restart Modu manually.") }
            let handoff = try await relauncher.launch(application: application, helper: helper, arguments: arguments, environment: environment)
            self.handoff = handoff
            let relauncher = relauncher
            handoffTask = Task { [weak self] in
                do {
                    let error = try await relauncher.waitForFailure(handoff)
                    guard !Task.isCancelled else { return }
                    self?.fail(error)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(error)
                }
            }
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func fail(_ error: Error) {
        if let handoff { relauncher.cancel(handoff); relauncher.discard(handoff) }
        handoffTask?.cancel(); handoffTask = nil
        handoff = nil; restartPending = false
        onFailure?(error)
    }
}
