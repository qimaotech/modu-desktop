import AppKit
import SwiftUI
import Testing
@testable import ModuDesktop

@MainActor struct RepositorySearchFieldTests {
    @Test(arguments: [false, true])
    func nativeEditsPublishBeforeFocusChanges(_ usesFieldEditor: Bool) {
        var text = "FRONT"
        var focused = false
        let view = RepositorySearchField(text: Binding(get: { text }, set: { text = $0 }),
                                         focused: Binding(get: { focused }, set: { focused = $0 }), placeholder: "Search")
        let coordinator = view.makeCoordinator()
        let field = NSSearchField(string: usesFieldEditor ? "FRONT" : "server")
        field.delegate = coordinator
        let editor = NSTextView()
        editor.string = "server"

        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field,
                                                         userInfo: usesFieldEditor ? ["NSFieldEditor": editor] : nil))
        #expect(text == "server")
        field.delegate?.controlTextDidBeginEditing?(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        #expect(focused && text == "server")
    }

    @Test func markedTextIsPublishedOnlyAfterCompositionFinishes() throws {
        var text = ""
        let view = RepositorySearchField(text: Binding(get: { text }, set: { text = $0 }), focused: .constant(true), placeholder: "Search")
        let coordinator = view.makeCoordinator()
        let field = NSSearchField()
        field.delegate = coordinator
        let editor = NSTextView()
        editor.setMarkedText("需求", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        try #require(editor.hasMarkedText())
        let change = Notification(name: NSControl.textDidChangeNotification, object: field, userInfo: ["NSFieldEditor": editor])

        field.delegate?.controlTextDidChange?(change)
        #expect(text.isEmpty)
        editor.unmarkText()
        field.delegate?.controlTextDidChange?(change)
        #expect(text == "需求")
    }
}
