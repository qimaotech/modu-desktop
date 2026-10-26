import AppKit
import Carbon
import Observation

@MainActor @Observable
final class GlobalShortcutModel {
    private let preferences: AppPreferences
    private let registration = GlobalShortcutRegistration()
    private var action: (@MainActor () -> Void)?
    private var started = false
    private(set) var isRecording = false
    var error: String?
    var shortcut: GlobalShortcut? { preferences.globalShortcut }
    var shortcutLabel: String? { shortcut?.displayValue.replacingOccurrences(of: "Space", with: t("Space", "空格")) }

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func start(action: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        self.action = action
        restoreShortcut()
    }

    func stop() {
        started = false
        isRecording = false
        registration.unregister()
        action = nil
    }

    func beginRecording() {
        guard !isRecording else { return }
        error = nil
        isRecording = true
        registration.unregister()
    }

    func record(_ event: NSEvent) {
        guard isRecording, event.type == .keyDown else { return }
        if event.keyCode == kVK_Escape { cancelRecording(); return }
        guard !event.isARepeat else { return }
        let shortcut = GlobalShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags)
        guard shortcut.isValid else { NSSound.beep(); return }
        do {
            try register(shortcut)
            preferences.globalShortcut = shortcut
            isRecording = false
            error = nil
        } catch { reportRegistrationError() }
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        restoreShortcut()
    }

    func clear() {
        registration.unregister()
        preferences.globalShortcut = nil
        isRecording = false
        error = nil
    }

    func t(_ english: String, _ chinese: String) -> String { preferences.t(english, chinese) }

    private func restoreShortcut() {
        guard started, let shortcut else { return }
        do { try register(shortcut) }
        catch { reportRegistrationError() }
    }

    private func register(_ shortcut: GlobalShortcut) throws {
        try registration.register(shortcut) { [weak self] in
            guard let self, self.started, !self.isRecording else { return }
            self.action?()
        }
    }

    private func reportRegistrationError() {
        error = t("This shortcut is unavailable. Choose a different combination.", "此快捷键无法使用，请选择其他组合。")
    }
}
