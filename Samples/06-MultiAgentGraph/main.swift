// 06 - Multi-Agent Graph
// Three analysis agents run in parallel on the same text, then an editor
// synthesizes their feedback. Demonstrates DAG-based parallel execution.

import Foundation
import StrandsAgents
import StrandsBedrockProvider

let provider = try BedrockProvider(config: BedrockConfig(
    modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
    region: "us-east-1"
))

let grammarAgent = Agent(
    model: provider,
    systemPrompt: "You are a grammar expert. Review the text for grammar and spelling errors. List each issue with the correction. Be concise."
)

let toneAgent = Agent(
    model: provider,
    systemPrompt: "You analyze writing tone. Is it formal, casual, persuasive, neutral? Suggest improvements to make it clearer and more engaging. Be concise."
)

let clarityAgent = Agent(
    model: provider,
    systemPrompt: "You evaluate writing clarity. Flag confusing sentences, jargon, or ambiguous phrasing. Suggest simpler alternatives. Be concise."
)

let editorAgent = Agent(
    model: provider,
    systemPrompt: "You are a senior editor. You will receive grammar, tone, and clarity feedback for a draft. Synthesize them into a short, prioritized list of the 3 most important improvements."
)

let graph = GraphOrchestrator(nodes: [
    // Stage 1: three analysis agents run in parallel
    GraphNode(id: "grammar", agent: grammarAgent),
    GraphNode(id: "tone",    agent: toneAgent),
    GraphNode(id: "clarity", agent: clarityAgent),

    // Stage 2: editor waits for all three, then synthesizes
    GraphNode(id: "editor", agent: editorAgent, dependencies: ["grammar", "tone", "clarity"]),
])

let draft = """
The new feature is very good and it makes things work better. \
Users can now do stuff that they couldnt before which is great. \
We think this will be impactful for the business going forward \
and we look forward to seeing how it performs in the market.
"""

print("Analyzing draft with 4 agents (3 parallel + 1 synthesis)...\n")

let result = try await graph.run("Review this draft:\n\n\(draft)")

print("=== Editor's Synthesis ===\n")
print(result.finalResult?.message.textContent ?? "")

// Show individual analyses
print("\n=== Individual Analyses ===")
for key in ["grammar", "tone", "clarity"] {
    print("\n[\(key)]")
    print(result.nodeResults[key]?.message.textContent ?? "(no output)")
}
