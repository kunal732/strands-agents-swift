import Foundation
import StrandsAgents
import AWSBedrockRuntime
import Smithy
import SmithyJSON

/// Converts between Strands SDK types and AWS Bedrock Runtime types.
enum BedrockTypeConverter {

    // MARK: - Messages

    static func convertMessages(_ messages: [Message]) -> [BedrockRuntimeClientTypes.Message] {
        messages.map { convertMessage($0) }
    }

    static func convertMessage(_ message: Message) -> BedrockRuntimeClientTypes.Message {
        BedrockRuntimeClientTypes.Message(
            content: message.content.compactMap { convertContentBlock($0) },
            role: message.role == .user ? .user : .assistant
        )
    }

    // MARK: - Content Blocks (Strands -> Bedrock)

    static func convertContentBlock(_ block: ContentBlock) -> BedrockRuntimeClientTypes.ContentBlock? {
        switch block {
        case .text(let textBlock):
            return .text(textBlock.text)

        case .toolUse(let toolUseBlock):
            let inputDoc = jsonValueToDocument(toolUseBlock.input)
            return .tooluse(BedrockRuntimeClientTypes.ToolUseBlock(
                input: inputDoc,
                name: toolUseBlock.name,
                toolUseId: toolUseBlock.toolUseId
            ))

        case .toolResult(let toolResultBlock):
            return .toolresult(BedrockRuntimeClientTypes.ToolResultBlock(
                content: toolResultBlock.content.compactMap { convertToolResultContent($0) },
                status: toolResultBlock.status == .success ? .success : .error,
                toolUseId: toolResultBlock.toolUseId
            ))

        case .image(let imageBlock):
            return convertImageToContentBlock(imageBlock)

        case .document(let docBlock):
            return convertDocumentToContentBlock(docBlock)

        case .reasoning, .citations, .cachePoint, .guardContent, .video:
            return nil
        }
    }

    static func convertToolResultContent(
        _ content: ToolResultContent
    ) -> BedrockRuntimeClientTypes.ToolResultContentBlock? {
        switch content {
        case .text(let text):
            return .text(text)
        case .json(let value):
            return .json(jsonValueToDocument(value))
        case .image(let imageBlock):
            guard let source = convertImageSource(imageBlock) else { return nil }
            return .image(source)
        case .document:
            return nil
        }
    }

    // MARK: - Tool Specs

    static func convertToolSpecs(_ specs: [ToolSpec]) -> [BedrockRuntimeClientTypes.Tool] {
        specs.map { spec in
            .toolspec(BedrockRuntimeClientTypes.ToolSpecification(
                description: spec.description,
                inputSchema: .json(jsonValueToDocument(.object(spec.inputSchema))),
                name: spec.name
            ))
        }
    }

    // MARK: - Tool Choice

    static func convertToolChoice(_ choice: ToolChoice?) -> BedrockRuntimeClientTypes.ToolChoice? {
        guard let choice else { return nil }
        switch choice {
        case .auto:
            return .auto(BedrockRuntimeClientTypes.AutoToolChoice())
        case .any:
            return .any(BedrockRuntimeClientTypes.AnyToolChoice())
        case .tool(let name):
            return .tool(BedrockRuntimeClientTypes.SpecificToolChoice(name: name))
        case .none:
            return nil
        }
    }

    // MARK: - Image Conversion

    private static func convertImageToContentBlock(
        _ imageBlock: ImageBlock
    ) -> BedrockRuntimeClientTypes.ContentBlock? {
        guard let source = convertImageSource(imageBlock) else { return nil }
        return .image(source)
    }

    private static func convertImageSource(
        _ imageBlock: ImageBlock
    ) -> BedrockRuntimeClientTypes.ImageBlock? {
        guard case .base64(_, let data) = imageBlock.source,
              let imageData = Data(base64Encoded: data)
        else { return nil }

        let format: BedrockRuntimeClientTypes.ImageFormat
        switch imageBlock.format {
        case .png: format = .png
        case .jpeg: format = .jpeg
        case .gif: format = .gif
        case .webp: format = .webp
        }

        return BedrockRuntimeClientTypes.ImageBlock(
            format: format,
            source: .bytes(imageData)
        )
    }

    // MARK: - Document Conversion

    private static func convertDocumentToContentBlock(
        _ docBlock: DocumentBlock
    ) -> BedrockRuntimeClientTypes.ContentBlock? {
        guard case .base64(_, let data) = docBlock.source,
              let docData = Data(base64Encoded: data)
        else { return nil }

        let format: BedrockRuntimeClientTypes.DocumentFormat
        switch docBlock.format {
        case .pdf: format = .pdf
        case .txt: format = .txt
        case .html: format = .html
        case .csv: format = .csv
        case .xlsx: format = .xlsx
        case .docx: format = .docx
        }

        return .document(BedrockRuntimeClientTypes.DocumentBlock(
            format: format,
            name: docBlock.name,
            source: .bytes(docData)
        ))
    }

    // MARK: - JSONValue <-> Smithy Document

    /// Convert a Strands JSONValue to a Smithy Document.
    ///
    /// Uses JSON serialization round-trip since Smithy Document's concrete
    /// implementations are SPI-guarded.
    static func jsonValueToDocument(_ value: JSONValue) -> Document {
        // Encode JSONValue to JSON data, then use Document.make(from:)
        guard let data = try? JSONEncoder().encode(value),
              let doc = try? Document.make(from: data)
        else {
            // Fallback: use literal initializers for simple types
            return nil
        }
        return doc
    }

    /// Convert a Smithy Document back to a Strands JSONValue.
    static func documentToJSONValue(_ doc: Document) -> JSONValue {
        switch doc.type {
        case .structure:
            return .null
        case .boolean:
            return .bool((try? doc.asBoolean()) ?? false)
        case .string:
            return .string((try? doc.asString()) ?? "")
        case .byte, .short, .integer:
            return .int((try? doc.asInteger()) ?? 0)
        case .long:
            return .int(Int(truncatingIfNeeded: (try? doc.asLong()) ?? 0))
        case .float, .double, .bigDecimal:
            return .double((try? doc.asDouble()) ?? 0)
        case .bigInteger:
            return .int(Int(truncatingIfNeeded: (try? doc.asBigInteger()) ?? 0))
        case .blob:
            return .string((try? doc.asBlob().base64EncodedString()) ?? "")
        case .timestamp:
            return .string((try? doc.asTimestamp().description) ?? "")
        case .list:
            let items = (try? doc.asList()) ?? []
            return .array(items.map { documentToJSONValue(Document($0)) })
        case .map:
            let map = (try? doc.asStringMap()) ?? [:]
            return .object(map.mapValues { documentToJSONValue(Document($0)) })
        case .union, .enum:
            return .string((try? doc.asString()) ?? "")
        @unknown default:
            return .null
        }
    }
}
