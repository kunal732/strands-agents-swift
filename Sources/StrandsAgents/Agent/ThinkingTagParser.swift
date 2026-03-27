/// Parses streaming text tokens and separates `<think>...</think>` content
/// from regular response content, routing each token to the correct event type.
///
/// Handles partial tokens -- `<think>` may arrive split across multiple deltas.
// @unchecked Sendable is safe here because process() is always called serially
// from the StreamAggregator's onTextDelta callback.
final class ThinkingTagParser: @unchecked Sendable {
    private var buffer = ""
    private var insideThink = false

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    /// Process a single incoming token. Returns the events to emit.
    func process(_ token: String) -> [AgentStreamEvent] {
        buffer += token
        return drain()
    }

    /// Flush any remaining buffered content at end of stream.
    func flush() -> [AgentStreamEvent] {
        guard !buffer.isEmpty else { return [] }
        let event: AgentStreamEvent = insideThink ? .thinkingDelta(buffer) : .textDelta(buffer)
        buffer = ""
        return [event]
    }

    private func drain() -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []

        while !buffer.isEmpty {
            let tag = insideThink ? Self.closeTag : Self.openTag

            if let range = buffer.range(of: tag) {
                // Emit everything before the tag
                let before = String(buffer[buffer.startIndex..<range.lowerBound])
                if !before.isEmpty {
                    events.append(insideThink ? .thinkingDelta(before) : .textDelta(before))
                }
                buffer.removeSubrange(buffer.startIndex...range.upperBound)
                insideThink.toggle()
            } else {
                // Check if the buffer tail could be a partial tag prefix
                let safe = safePrefixLength(buffer, avoiding: tag)
                if safe == 0 { break }  // entire buffer could be partial tag -- wait
                let emit = String(buffer.prefix(safe))
                events.append(insideThink ? .thinkingDelta(emit) : .textDelta(emit))
                buffer.removeFirst(safe)
            }
        }

        return events
    }

    /// Returns the number of characters we can safely emit without risking
    /// splitting a tag across two deltas. We hold back any suffix of `text`
    /// that is a prefix of `tag`.
    private func safePrefixLength(_ text: String, avoiding tag: String) -> Int {
        for holdBack in 1...min(text.count, tag.count) {
            let suffix = String(text.suffix(holdBack))
            if tag.hasPrefix(suffix) {
                return text.count - holdBack
            }
        }
        return text.count
    }
}
