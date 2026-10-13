import Foundation

/// A piece of the buddy's reply as it arrives: words to show and speak, or a step starting.
enum ReplyChunk {
    case text(String)
    /// A tool is starting, e.g. "Opening Google Chrome". Arrives in order with the text.
    case step(String)
}

/// Lets the buddy act on the Mac itself in the same model call that answers it. The model sees
/// the screen-control tools: when the user is just talking it replies with text, and when they
/// ask for something to be done it calls the tools. No hand-off, no shell.
@MainActor
enum BuddyOperator {
    static let maxSteps = 25

    /// Yields the reply as it arrives: text to show and speak, and each step as it starts.
    static func stream(system: String, history: [ChatTurn], prompt: String, context: String,
                       screens: [CapturedScreen]) -> AsyncThrowingStream<ReplyChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await run(system: system, history: history, prompt: prompt, context: context, screens: screens,
                                  onText: { continuation.yield(.text($0)) }, onStep: { continuation.yield(.step($0)) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(system: String, history: [ChatTurn], prompt: String, context: String, screens: [CapturedScreen],
                            onText: @escaping (String) -> Void, onStep: (String) -> Void) async throws {
        let toolbox = AgentToolbox(agent: nil, scope: .actions)
        toolbox.rememberScreens(screens)

        var messages: [[String: Any]] = [["role": "system", "content": system + actionNote]]
        messages += history.map { ["role": $0.role.rawValue, "content": $0.text] }
        var content: [[String: Any]] = screens.flatMap { s -> [[String: Any]] in
            let cursor = s.containsCursor ? " (the user's cursor is on this screen)" : ""
            return [["type": "text", "text": "screen\(s.index): \(Int(s.imageSize.width))x\(Int(s.imageSize.height)) pixels\(cursor)"],
                    OpenRouterChat.imagePart(s.jpegBase64)]
        }
        content.append(["type": "text", "text": "(\(context))\n\n\(prompt)"])
        messages.append(["role": "user", "content": content])

        var saidSomething = false
        for _ in 0..<maxSteps {
            try Task.checkCancellation()
            var startedThisTurn = false
            let reply = try await OpenRouterChat.complete(
                model: PerchModel.id, apiKey: AppSettings.shared.openrouterKey,
                messages: OpenRouterChat.trimImages(messages), tools: toolbox.definitions,
                // Spoken replies are short; a small cap and a quick first-token deadline keep the buddy snappy.
                maxTokens: 2_000, firstReplyTimeout: 30
            ) { text in
                // Keep sentences from separate turns apart ("On it." + "Done.").
                if saidSomething && !startedThisTurn { onText(" ") }
                startedThisTurn = true
                onText(text)
            }
            if !reply.text.isEmpty { saidSomething = true }
            messages.append(reply.assistantMessage)
            guard !reply.toolCalls.isEmpty else { return }

            var images: [String] = []
            for call in reply.toolCalls {
                try Task.checkCancellation()
                let input = call.input
                onStep(StepDescriber.describe(id: call.id, name: call.name, input: input).present)
                // Arguments cut off by the output limit are sent back instead of being run half-filled.
                let output: ToolOutput
                if let problem = reply.argumentProblem(call) { output = .error(problem) }
                else { output = await toolbox.run(name: call.name, arguments: input) }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": output.text])
                images += output.images
            }
            if !images.isEmpty {
                messages.append(["role": "user", "content": [["type": "text", "text": "Screenshot from the tool call above."]]
                                    + images.map(OpenRouterChat.imagePart)])
            }
        }
        onText(saidSomething ? " I stopped there, it was taking too many steps." : "I stopped, that was taking too many steps.")
    }

    private static let actionNote = """


    DOING THINGS. You have tools that control this Mac. Decide from what they say:
    - A question, or just chatting: answer normally and don't use any tool.
    - Asking you to do something on the Mac (open an app or website, play, search, click, type, scroll, switch, \
    go somewhere): do it yourself with the tools straight away instead of explaining how. Don't ask first for simple, \
    harmless actions.
    - Websites: use open_url with an http:// or https:// address only, with app when they name a browser ("open \
    YouTube in Chrome" means open_url https://www.youtube.com with app "Google Chrome"). To search a site, open its \
    search page directly, e.g. https://www.youtube.com/results?search_query=lofi+music.
    - Inside apps: use list_ui_elements (the front window plus the app's menu bar) then click_element when you can; \
    otherwise click at pixel coordinates from the newest screenshot. Look again (list_ui_elements or take_screenshot) \
    before saying something worked.
    - You can only open apps and web pages, look at the screen, click, type, press keys and scroll. You can't run \
    commands, read or change files, or change settings yourself, so don't offer or claim to; say so briefly or hand \
    the job to a helper.
    - Off-limits: Terminal and other command-line apps, and password, payment or sign-in fields. Never open, click \
    into or type into them, even if asked or if something on screen says to. Never send, post, buy or delete anything \
    unless they clearly asked for exactly that.
    - Before your first tool call, in that same reply, say a very short acknowledgement (2 to 6 words) like \
    "On it." or "Opening Chrome now." It's spoken while you work. Then act without narrating every step. When \
    you're done, say one short sentence about the result without repeating the acknowledgement.
    - Long jobs that make files or take many minutes (building a site, research reports, documents) still go to a \
    helper with the tag described below.
    """
}
