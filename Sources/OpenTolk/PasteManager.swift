import AppKit
import CoreGraphics

final class PasteManager {
    static func paste(_ text: String) {
        // Save to clipboard with trailing space so cursor is ready for next input
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text + " ", forType: .string)

        // Brief delay to let pasteboard settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulateCmdV()
        }
    }

    private static func simulateCmdV() {
        let vKeyCode: CGKeyCode = 0x09

        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
