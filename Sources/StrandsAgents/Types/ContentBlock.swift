import Foundation

/// A content block within a message. Mirrors the Bedrock/Anthropic content block model.
public enum ContentBlock: Sendable, Codable {
    case text(TextBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case image(ImageBlock)
    case document(DocumentBlock)
    case video(VideoBlock)
    case reasoning(ReasoningBlock)
    case citations(CitationsBlock)
    case cachePoint
    case guardContent(GuardContentBlock)
}

// MARK: - Block Types

public struct TextBlock: Sendable, Codable, Hashable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ToolUseBlock: Sendable, Codable {
    public var toolUseId: String
    public var name: String
    public var input: JSONValue

    public init(toolUseId: String, name: String, input: JSONValue) {
        self.toolUseId = toolUseId
        self.name = name
        self.input = input
    }
}

public struct ToolResultBlock: Sendable, Codable {
    public var toolUseId: String
    public var status: ToolResultStatus
    public var content: [ToolResultContent]

    public init(toolUseId: String, status: ToolResultStatus, content: [ToolResultContent]) {
        self.toolUseId = toolUseId
        self.status = status
        self.content = content
    }
}

public enum ToolResultStatus: String, Sendable, Codable {
    case success
    case error
}

public enum ToolResultContent: Sendable, Codable {
    case text(String)
    case json(JSONValue)
    case image(ImageBlock)
    case document(DocumentBlock)
}

public struct ImageBlock: Sendable, Codable, Hashable {
    public var format: ImageFormat
    public var source: ImageSource

    public init(format: ImageFormat, source: ImageSource) {
        self.format = format
        self.source = source
    }
}

public enum ImageFormat: String, Sendable, Codable, Hashable {
    case png
    case jpeg
    case gif
    case webp
}

public enum ImageSource: Sendable, Codable, Hashable {
    case base64(mediaType: String, data: String)
    case url(String)
}

public struct DocumentBlock: Sendable, Codable, Hashable {
    public var format: DocumentFormat
    public var name: String
    public var source: DocumentSource

    public init(format: DocumentFormat, name: String, source: DocumentSource) {
        self.format = format
        self.name = name
        self.source = source
    }
}

public enum DocumentFormat: String, Sendable, Codable, Hashable {
    case pdf
    case txt
    case html
    case csv
    case xlsx
    case docx
}

public enum DocumentSource: Sendable, Codable, Hashable {
    case base64(mediaType: String, data: String)
}

public struct VideoBlock: Sendable, Codable, Hashable {
    public var format: VideoFormat
    public var source: VideoSource

    public init(format: VideoFormat, source: VideoSource) {
        self.format = format
        self.source = source
    }
}

public enum VideoFormat: String, Sendable, Codable, Hashable {
    case mp4
    case mov
    case webm
}

public enum VideoSource: Sendable, Codable, Hashable {
    case base64(mediaType: String, data: String)
}

public struct ReasoningBlock: Sendable, Codable, Hashable {
    public var text: String?
    public var signature: String?

    public init(text: String? = nil, signature: String? = nil) {
        self.text = text
        self.signature = signature
    }
}

public struct CitationsBlock: Sendable, Codable {
    public var citations: [Citation]

    public init(citations: [Citation]) {
        self.citations = citations
    }
}

public struct Citation: Sendable, Codable {
    public var startIndex: Int?
    public var endIndex: Int?
    public var documentTitle: String?
    public var documentUrl: String?

    public init(startIndex: Int? = nil, endIndex: Int? = nil, documentTitle: String? = nil, documentUrl: String? = nil) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.documentTitle = documentTitle
        self.documentUrl = documentUrl
    }
}

public struct GuardContentBlock: Sendable, Codable, Hashable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

// MARK: - Convenience

extension ContentBlock {
    /// Extract text content, if this is a text block.
    public var text: String? {
        if case .text(let block) = self { return block.text }
        return nil
    }

    /// Extract tool use, if this is a tool use block.
    public var toolUse: ToolUseBlock? {
        if case .toolUse(let block) = self { return block }
        return nil
    }

    /// Extract tool result, if this is a tool result block.
    public var toolResult: ToolResultBlock? {
        if case .toolResult(let block) = self { return block }
        return nil
    }
}
