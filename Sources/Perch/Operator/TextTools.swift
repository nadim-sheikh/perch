import AppKit
import os
import ApplicationServices
import SwiftUI

/// Two text helpers that work in any app's focused text field:
/// - Dictation: hold a hotkey, speak, and the words are typed at the caret.
/// - Fix text: press a hotkey and the selected text (or the whole field) has its
///   spelling and grammar cleaned up in place.
@MainActor
final class TextTools {
    private let log = Logger(subsystem: "dev.perch.app", category: "texttools")
    static let shared = TextTools()

    private let speech = SpeechRecognizer()
    private let state = BuddyState.shared
    private var dictating = false
    private var busyFixing = false
    private var hideWork: DispatchWorkItem?

    // MARK: Dictation (hold to speak, inserts at the caret)

    func startDictation() {
        guard !dictating, !busyFixing else { return }
        dictating = true
        hideWork?.cancel()
        speech.onLevel = { [weak self] l in self?.state.audioLevel = l }
        speech.onPartial = { [weak self] t in
            guard self?.dictating == true else { return }
            self.map { $0.state.bubbleText = t.isEmpty ? "Listening…" : t }
        }
        state.phase = .listening
        state.bubbleText = "Listening…"
        Task {
            do { try await speech.start() }
            catch { flash("Couldn't reach the mic.") }
        }
    }

    func endDictation() {
        guard dictating else { return }
        dictating = false
        Task {
            state.phase = .thinking
            let text = await speech.stop()
            state.phase = .idle
            state.bubbleText = ""
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            // Type the words where the user's caret is, in whatever app is in front.
            ComputerControl.type(clean + " ")
        }
    }

    // MARK: Fix spelling & grammar (press once)

    func fixFocusedText() {
        DebugLog.write("fixFocusedText fired")
        guard !busyFixing, !dictating else { DebugLog.write("busy/dictating, skip"); return }
        guard AppSettings.shared.hasAnyKey else { DebugLog.write("no api key"); flash("Add an API key in Settings first."); return }
        guard let el = Self.focusedTextElement() else { DebugLog.write("no focused text element"); flash("Click into a text box first."); return }

        let selected = Self.string(el, kAXSelectedTextAttribute) ?? ""
        let whole = Self.string(el, kAXValueAttribute) ?? ""
        let hasSelection = !selected.trimmingCharacters(in: .whitespaces).isEmpty
        let source = hasSelection ? selected : whole
        DebugLog.write("element ok; hasSelection=\(hasSelection) selLen=\(selected.count) wholeLen=\(whole.count)")

        guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { flash("Nothing to fix here."); return }
        guard source.count <= 4000 else { flash("That's a lot. Select the part you want fixed."); return }

        busyFixing = true
        state.phase = .thinking
        state.bubbleText = "Fixing…"
        Task {
            let fixed = await Self.correct(source)
            state.phase = .idle
            busyFixing = false
            guard let fixed, fixed != source else {
                flash(fixed == nil ? "Couldn't fix that one." : "Looks good already.")
                return
            }
            DebugLog.write("replacing; fixedLen=\(fixed.count)")
            replace(in: el, hadSelection: hasSelection, with: fixed)
            flash("Fixed it.")
        }
    }

    /// Writes the corrected text back: straight into the field when we can, else by
    /// re-selecting and typing.
    private func replace(in el: AXUIElement, hadSelection: Bool, with text: String) {
        if hadSelection {
            if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success { return }
            ComputerControl.type(text)   // selection is already highlighted, so typing replaces it
            return
        }
        if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) == .success { return }
        // Fallback: select everything in the field, then type.
        ComputerControl.key("cmd+a")
        usleep(40_000)
        ComputerControl.type(text)
    }

    // MARK: Helpers

    private func flash(_ message: String) {
        state.bubbleText = message
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            withAnimation { self?.state.bubbleText = "" }
            self?.state.phase = .idle
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: w)
    }

    private static func focusedTextElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var el: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &el) == .success, let e = el else { return nil }
        let element = e as! AXUIElement
        let role = string(element, kAXRoleAttribute) ?? ""
        let editable: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        if editable.contains(role) { return element }
        // Some web/editor fields report a generic role but still carry a value.
        if string(element, kAXValueAttribute) != nil { return element }
        return nil
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func correct(_ text: String) async -> String? {
        let s = AppSettings.shared
        let client = LLMClient(provider: s.provider, apiKey: s.activeKey, model: s.replyModel)
        let system = """
        You are a precise copy editor. Fix only spelling, grammar and obvious typos in the user's text. \
        Keep the original meaning, tone, wording choices, language, capitalization style and line breaks. \
        Do not rephrase, translate, add, remove or explain anything. Reply with ONLY the corrected text, nothing else.
        """
        var out = ""
        do {
            for try await chunk in client.stream(system: system, history: [], prompt: text, screens: []) { out += chunk }
        } catch { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
