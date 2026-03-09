import Foundation
import StrandsAgents
import AWSBedrockRuntime

/// Converts Bedrock ConverseStream events to Strands ModelStreamEvent.
enum BedrockStreamAdapter {

    static func convert(
        _ event: BedrockRuntimeClientTypes.ConverseStreamOutput
    ) -> ModelStreamEvent? {
        switch event {
        case .messagestart(let msg):
            let role: Role = msg.role == .assistant ? .assistant : .user
            return .messageStart(role: role)

        case .contentblockstart(let block):
            let startData: ContentBlockStartData
            if let start = block.start {
                if case .tooluse(let tu) = start {
                    startData = ContentBlockStartData(
                        toolUse: ToolUseStart(
                            toolUseId: tu.toolUseId ?? "",
                            name: tu.name ?? ""
                        )
                    )
                } else {
                    startData = ContentBlockStartData()
                }
            } else {
                startData = ContentBlockStartData()
            }
            return .contentBlockStart(startData)

        case .contentblockdelta(let block):
            guard let delta = block.delta else { return nil }
            switch delta {
            case .text(let text):
                return .contentBlockDelta(.text(text))
            case .tooluse(let tu):
                return .contentBlockDelta(.toolUseInput(tu.input ?? ""))
            case .reasoningcontent(let rc):
                var text: String?
                var signature: String?
                if case .text(let t) = rc {
                    text = t
                } else if case .signature(let s) = rc {
                    signature = s
                }
                return .contentBlockDelta(.reasoning(text: text, signature: signature))
            case .citation, .image, .toolresult, .sdkUnknown:
                return nil
            @unknown default:
                return nil
            }

        case .contentblockstop:
            return .contentBlockStop

        case .messagestop(let msg):
            let stopReason = convertStopReason(msg.stopReason)
            return .messageStop(stopReason: stopReason)

        case .metadata(let meta):
            let usage: Usage?
            if let u = meta.usage {
                let inputToks = u.inputTokens ?? 0
                let outputToks = u.outputTokens ?? 0
                usage = Usage(
                    inputTokens: inputToks,
                    outputTokens: outputToks,
                    totalTokens: inputToks + outputToks,
                    cacheReadInputTokens: (u.cacheReadInputTokens ?? 0) != 0 ? u.cacheReadInputTokens : nil,
                    cacheWriteInputTokens: (u.cacheWriteInputTokens ?? 0) != 0 ? u.cacheWriteInputTokens : nil
                )
            } else {
                usage = nil
            }

            let metrics: InvocationMetrics?
            if let m = meta.metrics {
                metrics = InvocationMetrics(latencyMs: m.latencyMs ?? 0)
            } else {
                metrics = nil
            }

            return .metadata(usage: usage, metrics: metrics)

        case .sdkUnknown:
            return nil

        @unknown default:
            return nil
        }
    }

    private static func convertStopReason(
        _ reason: BedrockRuntimeClientTypes.StopReason?
    ) -> StopReason {
        guard let reason else { return .endTurn }
        switch reason {
        case .endTurn:
            return .endTurn
        case .toolUse:
            return .toolUse
        case .maxTokens:
            return .maxTokens
        case .stopSequence:
            return .stopSequence
        case .contentFiltered:
            return .contentFiltered
        case .guardrailIntervened:
            return .guardrailIntervened
        default:
            return .endTurn
        }
    }
}
