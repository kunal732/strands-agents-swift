import Foundation

enum MessageRole: String {
    case user
    case assistant
    case tool
    case system
    case thinking
}

enum ModelBackend: String, CaseIterable {
    case local = "Local (MLX)"
    case bedrock = "Bedrock (Claude)"
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    var content: String
    let timestamp = Date()
    var isStreaming: Bool = false
    var toolName: String? = nil
    var toolStatus: String? = nil
    var isThinkingDone: Bool = false
}
