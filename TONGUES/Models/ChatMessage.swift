import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String   // "user" or "assistant"
    let text: String
}
