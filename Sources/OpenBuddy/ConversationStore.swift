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

    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedID: UUID?
    /// Text of the reply currently streaming in (not yet saved).
    @Published var streamingText: String?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenBuddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved.sorted { $0.updated > $1.updated }
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

    private func save() {
        if let data = try? JSONEncoder().encode(conversations) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func title(from text: String) -> String {
        let words = text.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? "New chat" : words
    }
}
