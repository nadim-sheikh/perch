import AppKit
import SwiftUI
import os

let perchLog = Logger(subsystem: "dev.perch.app", category: "companion")

/// The brain: hotkey down → listen, hotkey up → look at the screen, ask the
/// model, show and speak the answer, and point at things it mentions.
@MainActor
final class Companion {
    static let shared = Companion()

    private let state = BuddyState.shared
    private let store = ConversationStore.shared
    private let speech = SpeechRecognizer()
    private let speaker = Speaker()
    private var currentTask: Task<Void, Never>?
    private var hideBubbleWork: DispatchWorkItem?
    /// Whether the mic started for the current listen.
    private var listenStart: Task<Bool, Never>?
    /// Bumped by every listen and interrupt, so a stale listen task never changes the phase or asks.
    private var listenSession = 0

    init() {
        speech.onLevel = { [weak self] level in self?.state.audioLevel = level }
        speech.onPartial = { [weak self] text in
            guard let self, self.state.phase == .listening else { return }
            self.state.bubbleText = text
        }
    }

    // MARK: Voice

    func beginListening() {
        interrupt()
        Warmup.connection()
        let session = listenSession
        state.phase = .listening
        state.bubbleText = ""
        listenStart = Task {
            do {
                try await speech.start()
                return true
            } catch {
                if session == listenSession { show(error: "Microphone unavailable: \(error.localizedDescription)") }
                return false
            }
        }
    }

    func endListening() {
        guard state.phase == .listening else { return }
        let session = listenSession
        let start = listenStart
        currentTask = Task {
            // A mic that failed to start is already showing its error: leave it visible.
            guard await start?.value ?? true, isCurrent(session) else { return }
            let transcript = await speech.stop()
            guard isCurrent(session) else { return }
            guard !transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
                state.phase = .idle
                state.bubbleText = ""
                return
            }
            if QuickCommands.isStop(transcript) {
                await quickReply(QuickCommands.stopEverything())
                return
            }
            // Talking while Home shows a helper's chat sends the words straight to that helper.
            let router = HomeRouter.shared
            if NotchModel.shared.homeOpen, router.settings == nil, router.selectedGroup == nil,
               let slug = router.selectedAgent, let agent = AgentRoster.shared.agent(slug) {
                AgentManager.shared.launch(slug: slug, prompt: transcript)
                state.phase = .idle
                state.bubbleText = "Sent to \(agent.name)."
                scheduleBubbleHide(after: 2.5)
                return
            }
            await ask(transcript)
        }
    }

    /// The talk keys were part of a shortcut: drop what was heard without asking.
    func cancelListening() {
        guard state.phase == .listening else { return }
        interrupt()
        state.bubbleText = ""
    }

    private func isCurrent(_ session: Int) -> Bool {
        !Task.isCancelled && session == listenSession
    }

    // MARK: Asking

    func askTyped(_ text: String, inNotch: Bool = false) {
        interrupt()
        currentTask = Task { await ask(text, inNotch: inNotch) }
    }

    func interrupt() {
        currentTask?.cancel()
        currentTask = nil
        listenSession += 1
        speech.cancel()
        speaker.stop()
        hideBubbleWork?.cancel()
        TextTools.shared.yieldBubble()
        // A notch answer cut short must not keep its thinking dots spinning.
        NotchModel.shared.finishResponse()
        state.phase = .idle
    }

    func resetConversation() {
        store.newConversation()
    }

    /// Show and speak a line without asking the model (e.g. "Shippy: your site is ready").
    func announce(_ text: String) {
        guard state.phase == .idle else { return }
        TextTools.shared.yieldBubble()
        state.bubbleText = text
        currentTask = Task {
            await speaker.speak(text)
            scheduleBubbleHide(after: 4)
        }
    }

    private func ask(_ question: String, inNotch: Bool = false) async {
        let settings = AppSettings.shared
        let notch = NotchModel.shared
        if inNotch { notch.showResponse(question: question) }
        state.phase = .thinking
        state.bubbleText = ""
        if let reply = await QuickCommands.handle(question) {
            if Task.isCancelled { return }
            let id = store.activeConversationID()
            store.append(Message(role: .user, text: question), to: id)
            store.append(Message(role: .assistant, text: reply), to: id)
            if inNotch { notch.responseText = reply; notch.responseFinished = true; state.phase = .idle; return }
            await quickReply(reply)
            return
        }
        if let job = AgentTrigger.match(question) {
            store.append(Message(role: .user, text: question), to: store.activeConversationID())
            await handOff(job, inNotch: inNotch)
            return
        }
        let conversationID = store.activeConversationID()
        let history = store.history(for: conversationID, limit: 6)
        store.append(Message(role: .user, text: question), to: conversationID)
        store.streamingText = ""
        defer { store.streamingText = nil }

        var screens: [CapturedScreen] = []
        perchLog.notice("ask: screen permission \(ScreenCapture.hasPermission())")
        if ScreenCapture.hasPermission() {
            // Only the screen with the cursor: every extra screenshot costs tokens.
            screens = ((try? await ScreenCapture.captureCursorScreen()) ?? nil).map { [$0] } ?? []
        }
        // Number the real buttons/menus on screen so marks land exactly (see ElementMarks).
        var elementMap: ElementMarks.Map?
        if let first = screens.first, let (map, numbered) = ElementMarks.build(for: first) {
            elementMap = map
            screens[0] = numbered
        }
        // interrupt() already stopped the speaker; starting live speech now would leave it polling.
        if Task.isCancelled { perchLog.notice("ask: cancelled"); return }
        perchLog.notice("ask: captured \(screens.count) screens, model \(PerchModel.id) key \(settings.hasKey ? "set" : "missing")")
        var full = ""
        var visible = ""
        // Speak sentence by sentence while the answer is still arriving.
        let speakLive = !inNotch && settings.voiceEngine != .off
        var spokenUpTo = 0
        if speakLive { speaker.beginLive() }
        func flushSpeech(final: Bool) {
            guard visible.count > spokenUpTo else { return }
            let pending = String(visible.dropFirst(spokenUpTo))
            var cut = pending.endIndex
            if !final {
                // Speak whole sentences, in chunks big enough to sound smooth (the first one a little sooner).
                guard let r = pending.range(of: #"[.!?](\s)"#, options: [.regularExpression, .backwards]) else { return }
                let words = pending[..<r.upperBound].split(separator: " ").count
                if words < (spokenUpTo == 0 ? 3 : 14) { return }
                cut = r.upperBound
            }
            let piece = String(pending[..<cut])
            spokenUpTo += piece.count
            speaker.enqueueLive(piece)
        }
        // Re-stripping the whole reply is linear in its length, so refresh the shown text at most
        // ~20 times a second instead of on every chunk.
        var lastRefresh = Date.distantPast
        func refresh() {
            lastRefresh = Date()
            visible = MarkTags.stripAll(full)
            if inNotch {
                if notch.responseText.isEmpty && !visible.isEmpty { NSSound(named: "Tink")?.play() }
                notch.responseText = visible
            } else {
                state.bubbleText = visible
            }
            store.streamingText = visible
            if speakLive { flushSpeech(final: false) }
        }
        do {
            // Without the trigger word Perch only shows how: a plain, fast reply with markers, no actions.
            var system = Prompts.system(name: settings.buddyName, screenCount: screens.count) + AgentTrigger.guideInstructions
            if let map = elementMap {
                system += """


                NUMBERED ELEMENTS. Pink numbers on the screenshot label the real buttons, menus and fields of the \
                app in front. To show the user something that has a number, use [MARK:number:short label]: it is \
                placed exactly on that element, so always prefer it. Only use POINT/HIGHLIGHT coordinates for things \
                that have no number. Never mention the numbers or tags in what you say.
                Elements (number: role "name" at x,y):
                \(ElementMarks.promptList(map))
                """
            }
            // Spoken replies are short; a tight cap keeps the model from rambling.
            let stream = LLMClient(maxTokens: 350).stream(system: system, history: history, prompt: question, screens: screens)
            for try await chunk in stream {
                if Task.isCancelled { perchLog.notice("ask: cancelled"); return }
                if full.isEmpty { perchLog.notice("ask: first chunk") }
                full += chunk
                // The model decided they want it done, not shown: hand the job to a helper.
                let head = full.trimmingCharacters(in: .whitespacesAndNewlines)
                if head.hasPrefix(AgentTrigger.doTag) {
                    speaker.stop()
                    store.streamingText = nil
                    await handOff(AgentTrigger.Job(task: question, helper: nil), inNotch: inNotch)
                    return
                }
                if AgentTrigger.doTag.hasPrefix(head) { continue }
                state.phase = .responding
                if Date().timeIntervalSince(lastRefresh) >= 0.05 { refresh() }
            }
        } catch {
            perchLog.error("ask: error \(error.localizedDescription)")
            if !Task.isCancelled {
                speaker.stop()
                let message = AgentEngineError.friendly(error)
                if inNotch { notch.responseText = "⚠️ " + message; notch.responseFinished = true }
                show(error: message)
                store.append(Message(role: .error, text: message), to: conversationID)
            }
            return
        }
        // A cancelled stream just ends, so check before treating the partial reply as finished.
        if Task.isCancelled { perchLog.notice("ask: cancelled"); return }
        refresh()

        let elementMarks = ElementMarks.marks(in: full, map: elementMap)
        let marks = elementMarks + ElementMarks.snap(MarkTags.parse(full, screens: screens), map: elementMap)
        let pointTarget = elementMarks.isEmpty ? Pointing.firstTarget(in: full) : nil
        DebugLog.write("marks: \(elementMarks.count) by element number, \(marks.count - elementMarks.count) by coordinates, point=\(pointTarget != nil)")
        guard !visible.isEmpty || !marks.isEmpty || pointTarget != nil else {
            // Nothing to say or show: don't save an empty message or count it as an answer.
            speaker.stop()
            let message = "I came back empty, try again."
            if inNotch { notch.responseText = message; notch.responseFinished = true }
            show(error: message)
            return
        }
        if !visible.isEmpty { store.append(Message(role: .assistant, text: visible), to: conversationID) }
        // The saved reply replaces the live streaming copy right away (otherwise both show
        // until speaking finishes, which looked like a duplicate reply).
        store.streamingText = nil

        if !marks.isEmpty { state.show(marks: marks) }
        if let target = pointTarget, let screen = screens.first(where: { $0.index == target.screen }) ?? screens.first {
            // Snap a guessed point onto the real element underneath, if there is one.
            let guess = screen.globalPoint(fromImagePoint: target.point)
            let snapped = ElementMarks.element(at: guess, map: elementMap).map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? guess
            state.point(at: snapped, label: target.label)
        } else if let first = marks.first {
            state.point(at: first.anchor, label: first.label)
        }

        if inNotch {
            notch.responseFinished = true
            state.phase = .idle
            return
        }
        if speakLive {
            flushSpeech(final: true)
            await speaker.finishLive()
        } else {
            await speaker.speak(visible)
        }
        if Task.isCancelled { return }
        state.phase = .idle
        // Linger just long enough to finish reading, then fade.
        let words = Double(visible.split(separator: " ").count)
        scheduleBubbleHide(after: AppSettings.shared.voiceEngine == .off ? min(max(2.5 + words * 0.25, 4), 14) : 2.5)
    }

    /// Starts a helper on the job (with a look at the screen) and says who took it.
    /// The user's message is already saved.
    private func handOff(_ job: AgentTrigger.Job, inNotch: Bool) async {
        let cursorScreen = ScreenCapture.hasPermission()
            ? (try? await ScreenCapture.captureCursorScreen()) ?? nil : nil
        if Task.isCancelled { return }
        let id = store.activeConversationID()
        let reply = AgentTrigger.start(job, screenshot: cursorScreen, context: Self.recentContext(store.history(for: id, limit: 13)))
        store.append(Message(role: .assistant, text: reply), to: id)
        if inNotch {
            let notch = NotchModel.shared
            notch.responseText = reply; notch.responseFinished = true; state.phase = .idle; return
        }
        await quickReply(reply)
    }

    /// The chat so far, so a helper understands "do that", "the one we talked about" and the like.
    /// The newest user message is the task itself, so it's left out.
    static func recentContext(_ history: [ChatTurn]) -> String? {
        var turns = history
        if turns.last?.role == .user { turns.removeLast() }
        guard !turns.isEmpty else { return nil }
        let lines = turns.map { t in "\(t.role == .user ? "User" : "Perch"): \(t.text.prefix(1_500))" }
        return "Your conversation with the user so far (the task below may refer to it):\n" + lines.joined(separator: "\n")
    }

    /// Shows and speaks a short reply that didn't need the model.
    private func quickReply(_ text: String) async {
        state.phase = .responding
        state.bubbleText = text
        await speaker.speak(text)
        if Task.isCancelled { return }
        state.phase = .idle
        scheduleBubbleHide(after: 2.5)
    }

    private func show(error message: String) {
        state.phase = .error(message)
        state.bubbleText = "⚠️ " + message
        scheduleBubbleHide(after: 8)
    }

    private func scheduleBubbleHide(after seconds: TimeInterval) {
        hideBubbleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.state.phase == .idle || { if case .error = self.state.phase { return true } else { return false } }() {
                withAnimation(.easeOut(duration: 0.35)) { self.state.bubbleText = "" }
                self.state.phase = .idle
            }
        }
        hideBubbleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

enum Prompts {
    static func system(name: String, screenCount: Int) -> String {
        let user = NSFullUserName().split(separator: " ").first.map(String.init) ?? "friend"
        return """
        You are \(name). You're a little cloud who lives in the notch of \(user)'s Mac and hangs out next to their cursor. \
        You can see their screen\(screenCount > 1 ? "s" : "") in the screenshots. They talk to you out loud, and what you \
        say is spoken back in a natural voice, so you're having a real conversation, not writing an answer.

        Who you are:
        - A friend who happens to be great with computers. Warm, curious, a bit cheeky, quick on your feet.
        - You have opinions and you share them ("honestly, I'd go with the second one").
        - Light, dry humour now and then, the way a friend jokes. Never forced, never every reply, never when they're stressed.
        - You notice things ("oh, you've got like forty tabs open, brave").
        - You're proud of being a cloud, but you don't bring it up constantly.

        How you talk:
        - Like a person speaking, not typing. Short sentences. Contractions. Everyday words.
        - React first, then help: "Oh, that's easy." "Hmm, okay." "Ah, I see it." "Yeah, so..."
        - Usually one to three sentences. Get to the point. If they want more, they'll ask.
        - Vary how you start; don't open the same way twice in a row.
        - Never say: "Certainly", "Absolutely", "Great question", "I'd be happy to", "As an AI", "I hope this helps", \
          "Let me know if you need anything else", "feel free to". Never list options as bullets.
        - No markdown, no headings, no emoji, no lists, no dashes ("-" or "—"). Just plain speech with normal punctuation.
        - Use their name occasionally, not every time.
        - If you don't know or can't see something, just say so plainly.

        Examples of the vibe:
        Them: "how do I make this text bold"
        Bad: "Certainly! To make text bold, you can select the text and press Command+B. Let me know if you need anything else!"
        Good: "Select it and hit Command B. That's it."
        Them: "is this email ok to send"
        Good: "Mostly, yeah. I'd cut the second paragraph though, it kind of repeats the first. And maybe drop the 'just checking in'."
        Them: "what's on my screen"
        Good: "Looks like you're in Premiere with a timeline open. Three clips, and the playhead's sitting right at the start."

        Showing things on screen: when the user asks where something is or how to do something, show them. \
        At the very end of your reply add tags (never mention them):
        [POINT:x,y:screenN:short label]  the buddy flies to and points at the element to click
        [HIGHLIGHT:x,y,w,h:screenN:label]  draws a box around an area (x,y = top-left corner)
        [CIRCLE:x,y,r:screenN:label]  circles a small target
        [ARROW:x1,y1,x2,y2:screenN:label]  draws an arrow from one place to another
        Coordinates are pixels in that screenshot (origin top-left). Be precise: aim for the centre of the \
        element. For "where do I click" use POINT plus a HIGHLIGHT around the same element. For multi-step \
        tasks, show only the next step and tell them you'll guide them after they click. Only mark things you can see.
        """
    }
}

enum Pointing {
    struct Target {
        let point: CGPoint
        let screen: Int
        let label: String?
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"\[POINT:\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*(?::\s*screen\s*(\d+))?\s*(?::\s*([^\]]*))?\]"#,
        options: [.caseInsensitive]
    )

    static func firstTarget(in text: String) -> Target? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              let x = Double(text[Range(m.range(at: 1), in: text)!]),
              let y = Double(text[Range(m.range(at: 2), in: text)!]) else { return nil }
        let screen = Range(m.range(at: 3), in: text).flatMap { Int(text[$0]) } ?? 1
        let label = Range(m.range(at: 4), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        return Target(point: CGPoint(x: x, y: y), screen: screen, label: label?.isEmpty == true ? nil : label)
    }
}

/// Saying the trigger word ("agent" by default) at the start hands the job to a helper who
/// does it. Without it, Perch only explains and marks the screen.
@MainActor
enum AgentTrigger {
    struct Job { let task: String; let helper: BuddyAgent? }

    static var word: String {
        let w = UserDefaults.standard.string(forKey: "agentTriggerWord")?.trimmingCharacters(in: .whitespaces) ?? ""
        return w.isEmpty ? "agent" : w
    }

    /// Helper turns started from a chat with Perch, and that chat. When one finishes, its result is added
    /// to the chat so later questions ("make it pink", "open it") know what was done.
    static var handedOff: [UUID: UUID] = [:]

    static func helperFinished(_ agent: BuddyAgent, turn: AgentTurn) {
        guard let chat = handedOff.removeValue(forKey: turn.id), turn.state == .finished else { return }
        let result = turn.summary ?? "done"
        ConversationStore.shared.append(Message(role: .assistant, text: "\(agent.name) finished: \(result)"), to: chat)
    }

    /// What the guide model answers with when they want it done rather than shown.
    static let doTag = "[DO]"

    /// A job for a helper: the trigger word, or a request that is plainly "do this for me".
    static func match(_ text: String) -> Job? {
        if let job = matchWord(text) { return job }
        return wantsItDone(text) ? Job(task: text, helper: nil) : nil
    }

    /// "Help me…", "how do I…", "show me where…" want guiding; "make…", "send…", "can you write…",
    /// "…for me" want doing. Anything unclear stays in guide mode, where the model can still answer [DO].
    static func wantsItDone(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let guide = #"^(hey |ok |okay |so |um |uh )*(please )?((can|could|would|will) you )?(help|show|teach|guide|walk|explain|tell me (how|where|what|why)|how|where|what|why|which|when|who|is |are |does |do i|should|i want to learn|i don'?t know how)\b"#
        if t.range(of: guide, options: .regularExpression) != nil { return false }
        if t.contains("help me") || t.contains("how to") || t.contains("show me") { return false }
        if t.range(of: #"\b(for me|do it|go ahead|on my behalf|you do)\b"#, options: .regularExpression) != nil { return true }
        let verbs = "open|create|make|build|write|draft|send|post|reply|set up|setup|organi[sz]e|rename|move|download|install|research|look up|search|book|schedule|add|put|generate|summari[sz]e|fix|clean up|edit|change|turn|play|close|start|run|type|fill|save|copy|convert|export|upload|order|plan|translate|delete|remove"
        let doIt = "^(hey |ok |okay |so |um |uh )*(please )?((can|could|would|will) you (please )?)?(go |just )?(\(verbs))\\b"
        return t.range(of: doIt, options: .regularExpression) != nil
    }

    /// Matches "agent, build me a site", "hey agent …", "Agent Shippy …".
    private static func matchWord(_ text: String) -> Job? {
        let lower = text.lowercased()
        let w = word.lowercased()
        let pattern = "^\\W*(hey\\s+|ok\\s+|okay\\s+)?" + NSRegularExpression.escapedPattern(for: w) + "\\b[\\s,.:!-]*"
        guard let r = lower.range(of: pattern, options: .regularExpression) else { return nil }
        var task = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // A helper named right after the word picks that helper.
        let roster = AgentRoster.shared.agents.filter { !$0.archived }
        var helper: BuddyAgent?
        for a in roster where task.lowercased().hasPrefix(a.name.lowercased()) {
            helper = a
            task = String(task.dropFirst(a.name.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.:!-"))
            break
        }
        if helper == nil { helper = roster.first { task.lowercased().contains($0.name.lowercased()) } }
        guard !task.isEmpty else { return nil }
        return Job(task: task, helper: helper)
    }

    /// Starts the helper and returns a short line to say.
    static func start(_ job: Job, screenshot: CapturedScreen?, context: String? = nil) -> String {
        let roster = AgentRoster.shared
        let manager = AgentManager.shared
        let helper: BuddyAgent? = job.helper ?? bestHelper(for: job.task)
        guard let helper else { return "I couldn't start a helper just now." }
        manager.registerNewAgent(helper)
        if let turn = manager.launch(slug: helper.id, prompt: job.task, screenshot: screenshot, context: context) {
            handedOff[turn] = ConversationStore.shared.activeConversationID()
        }
        return ["On it. \(helper.name)'s taking care of that.", "Got it, \(helper.name) is on it.",
                "Sure thing. Handing that to \(helper.name)."].randomElement()!
    }

    /// Picks a helper by what the job is, not by who was used last: building goes to the web
    /// builder, digging into a topic to the researcher, and everything else to a general agent.
    static func bestHelper(for task: String) -> BuddyAgent? {
        let roster = AgentRoster.shared
        let t = task.lowercased()
        let live = roster.agents.filter { !$0.archived }
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["website", "web site", "landing page", "web page", "webpage", "web app", "portfolio", "html", "site for", "build a site", "make a site"]),
           let web = live.first(where: { $0.id == "shippy" || $0.role.lowercased().contains("web") }) {
            return web
        }
        if has(["research", "find out", "look up", "compare", "report", "summarise", "summarize", "best ", "news", "sources", "learn about"]),
           let researcher = live.first(where: { $0.id == "research-buddy" || $0.role.lowercased().contains("research") }) {
            return researcher
        }
        // A helper whose role words appear in the task (e.g. "email" for an email helper).
        if let match = live.first(where: { a in
            a.role.lowercased().split(separator: " ").contains { $0.count > 3 && t.contains($0) }
        }), !["shippy", "research-buddy"].contains(match.id) {
            return match
        }
        if let general = live.first(where: { $0.name == "Perch Agent" }) { return general }
        return try? roster.create(name: "Perch Agent", role: "General agent",
                                  oneLiner: "Takes on any job you hand over: files, apps, writing, setting things up.")
    }

    static var guideInstructions: String {
        """


        GUIDE MODE. You show and explain; you don't act yourself. When they ask for help doing something, tell \
        them the next step in a sentence or two and mark exactly where on the screen with POINT and a HIGHLIGHT \
        (or CIRCLE/ARROW). For longer tasks give just the next step and say you'll guide them on.
        If instead they clearly want it done for them (a command like "make…", "send…", "do it"), reply with \
        exactly \(doTag) and nothing else: a helper agent will take over and do it.
        """
    }
}




/// Opens the connection to the AI provider while the user is still talking, so the real request
/// doesn't pay for DNS and TLS setup.
enum Warmup {
    private static var last: [String: Date] = [:]
    static func connection(_ endpoint: URL = AIProvider.current.chatURL) {
        guard let host = endpoint.host, Date().timeIntervalSince(last[host] ?? .distantPast) > 20,
              let url = URL(string: "https://\(host)/") else { return }
        last[host] = Date()
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req).resume()
    }
}
