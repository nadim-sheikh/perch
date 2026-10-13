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
    private var dictationStart: Task<Bool, Never>?
    private var dictationToken = 0
    /// Who may change the buddy's phase and bubble: a TextTools job only touches them while
    /// the token it claimed is still current. Companion bumps it via `yieldBubble()`.
    private var owner = 0

    /// Companion is taking over the bubble: drop any pending hide, and stop running jobs
    /// from resetting the phase or bubble (they still finish their work).
    func yieldBubble() {
        owner += 1
        hideWork?.cancel()
        hideWork = nil
    }

    private func claimBubble() -> Int {
        yieldBubble()
        return owner
    }

    // MARK: Dictation (hold to speak, inserts at the caret)

    func startDictation() {
        guard !dictating, !busyFixing else { return }
        // Stop Perch talking first, or the mic types its voice into the field.
        Companion.shared.interrupt()
        dictating = true
        let token = claimBubble()
        dictationToken = token
        speech.onLevel = { [weak self] l in self?.state.audioLevel = l }
        speech.onPartial = { [weak self] t in
            guard let self, self.dictating, self.owner == token else { return }
            self.state.bubbleText = t.isEmpty ? "Listening…" : t
        }
        state.phase = .listening
        state.bubbleText = "Listening…"
        dictationStart = Task {
            do { try await speech.start(); return true }
            catch { flash("Couldn't reach the mic.", token: token); return false }
        }
    }

    func endDictation() {
        guard dictating else { return }
        dictating = false
        let start = dictationStart
        dictationStart = nil
        let token = dictationToken
        Task {
            // Let the mic finish starting so stopping really turns it off; a failure was already shown.
            guard await start?.value ?? false else { return }
            if owner == token { state.phase = .thinking }
            let text = await speech.stop()
            if owner == token {
                state.phase = .idle
                state.bubbleText = ""
            }
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
        guard AppSettings.shared.hasKey else { DebugLog.write("no api key"); flash("Add an API key in Settings first."); return }
        guard let el = Self.focusedTextElement() else { DebugLog.write("no focused text element"); flash("Click into a text box first."); return }

        let selected = Self.string(el, kAXSelectedTextAttribute) ?? ""
        let whole = Self.string(el, kAXValueAttribute) ?? ""
        let hasSelection = !selected.trimmingCharacters(in: .whitespaces).isEmpty
        let source = hasSelection ? selected : whole
        DebugLog.write("element ok; hasSelection=\(hasSelection) selLen=\(selected.count) wholeLen=\(whole.count)")

        guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { flash("Nothing to fix here."); return }
        guard source.count <= 4000 else { flash("That's a lot. Select the part you want fixed."); return }

        busyFixing = true
        let token = claimBubble()
        state.phase = .thinking
        state.bubbleText = "Fixing…"
        Task {
            let fixed: String?
            do {
                fixed = try await Self.correct(source)
            } catch {
                busyFixing = false
                DebugLog.write("fix failed: \(error.localizedDescription)")
                flash("Couldn't fix that. " + AgentEngineError.friendly(error), token: token, seconds: 6)
                return
            }
            busyFixing = false
            guard let fixed, fixed != source else {
                flash(fixed == nil ? "Couldn't fix that one." : "Looks good already.", token: token)
                return
            }
            DebugLog.write("replacing; fixedLen=\(fixed.count)")
            replace(in: el, hadSelection: hasSelection, with: fixed)
            flash("Fixed it.", token: token)
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

    /// Shows a short message, then clears it. `token` is the job's claim on the bubble
    /// (a new claim when omitted); nothing happens once Companion has taken over.
    private func flash(_ message: String, token: Int? = nil, seconds: TimeInterval = 2.2) {
        let token = token ?? claimBubble()
        guard token == owner else { return }
        state.phase = .idle
        state.bubbleText = message
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.owner == token else { return }
            withAnimation { self.state.bubbleText = "" }
            self.state.phase = .idle
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
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

    /// The corrected text, or nil for an empty reply. Throws unless the reply arrived complete,
    /// so a cut-off or failed stream never overwrites the user's text.
    private static func correct(_ text: String) async throws -> String? {
        let client = LLMClient()
        let system = """
        You are a precise copy editor. Check every word of the user's text and fix all spelling mistakes, \
        typos, misspelled contractions (e.g. "dident" → "didn't", "dont" → "don't"), wrong word forms \
        (e.g. "you're" vs "your", "there" vs "their") and grammar. Capitalize "I" and the first letter of each sentence. \
        Keep the original meaning, tone, wording choices, language and line breaks. \
        Do not rephrase, translate, add, remove or explain anything. Reply with ONLY the corrected text, nothing else.
        """
        var out = ""
        for try await chunk in client.stream(system: system, history: [], prompt: text, screens: []) { out += chunk }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
