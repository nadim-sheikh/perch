import Foundation

struct Message: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, error }
    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
}

struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var messages: [Message] = []
    var updated = Date()

    var preview: String { messages.last?.text ?? "No messages yet" }
}

/// Saved chats, persisted as JSON in Application Support.
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    /// Oldest chats, and the oldest messages in a long chat, are dropped past these.
    static let maxConversations = 200
    static let maxMessages = 300
    /// Writes are batched, then done off the main thread in order.
    private static let saveDelay: UInt64 = 1_000_000_000
    private static let ioQueue = DispatchQueue(label: "dev.perch.conversations.save", qos: .utility)
    private var saveTask: Task<Void, Never>?
    private var dirty = false

    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedID: UUID?
    /// Text of the reply currently streaming in (not yet saved).
    @Published var streamingText: String?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved.sorted { $0.updated > $1.updated }
            trim()
        }
    }

    var selected: Conversation? { conversations.first { $0.id == selectedID } }

    /// The conversation new voice questions go into: the selected one, or a fresh one.
    func activeConversationID() -> UUID {
        if let id = selectedID, conversations.contains(where: { $0.id == id }) { return id }
        return newConversation()
    }

    @discardableResult
    func newConversation() -> UUID {
        let c = Conversation(title: "New chat")
        conversations.insert(c, at: 0)
        selectedID = c.id
        trim()
        save()
        return c.id
    }

    func append(_ message: Message, to id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].messages.append(message)
        conversations[i].updated = Date()
        if conversations[i].title == "New chat", message.role == .user {
            conversations[i].title = Self.title(from: message.text)
        }
        let c = conversations.remove(at: i)
        conversations.insert(c, at: 0)
        trim()
        save()
    }

    func history(for id: UUID, limit: Int = 20) -> [ChatTurn] {
        guard let c = conversations.first(where: { $0.id == id }) else { return [] }
        return c.messages.suffix(limit).compactMap { m in
            switch m.role {
            case .user: return ChatTurn(role: .user, text: m.text)
            case .assistant: return ChatTurn(role: .assistant, text: m.text)
            case .error: return nil
            }
        }
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        save()
    }

    /// Keeps the newest chats (and the selected one) and the newest messages in each.
    private func trim() {
        for i in conversations.indices where conversations[i].messages.count > Self.maxMessages {
            conversations[i].messages.removeFirst(conversations[i].messages.count - Self.maxMessages)
        }
        guard conversations.count > Self.maxConversations else { return }
        let keep = Set(conversations.prefix(Self.maxConversations).map(\.id)).union(selectedID.map { [$0] } ?? [])
        conversations.removeAll { !keep.contains($0.id) }
    }

    /// Saves shortly after the last change, so a streamed answer doesn't rewrite the file over and over.
    private func save() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.dirty = false
            let snapshot = self.conversations
            let url = self.fileURL
            Self.ioQueue.async { Self.write(snapshot, to: url) }
        }
    }

    /// Writes any unsaved change now and waits for it. Call when Perch quits.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = dirty ? conversations : nil
        dirty = false
        let url = fileURL
        // Runs after any write already queued, so the newest data lands last.
        Self.ioQueue.sync { if let snapshot { Self.write(snapshot, to: url) } }
    }

    nonisolated private static func write(_ conversations: [Conversation], to url: URL) {
        if let data = try? JSONEncoder().encode(conversations) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func title(from text: String) -> String {
        let words = text.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? "New chat" : words
    }
}
