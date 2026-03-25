// 09 - Structured Output
// Forces the model to return a typed Swift struct instead of free-form text.
// Conform your struct to StructuredOutput and provide a jsonSchema.

import Foundation
import StrandsAgents

struct MovieRecommendation: Codable, StructuredOutput {
    let title: String
    let year: Int
    let genre: String
    let reason: String
    let rating: Double
    let streamingOn: [String]
    let similarMovies: [String]

    static var jsonSchema: JSONSchema {
        [
            "type": "object",
            "properties": [
                "title":         ["type": "string"],
                "year":          ["type": "integer"],
                "genre":         ["type": "string"],
                "reason":        ["type": "string"],
                "rating":        ["type": "number"],
                "streamingOn":   ["type": "array", "items": ["type": "string"]],
                "similarMovies": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["title", "year", "genre", "reason", "rating", "streamingOn", "similarMovies"]
        ]
    }
}

let agent = Agent(
    model: try BedrockProvider(config: BedrockConfig(
        modelId: "us.anthropic.claude-sonnet-4-20250514-v1:0",
        region: "us-east-1"
    ))
)

print("Asking for a structured movie recommendation...\n")

let movie: MovieRecommendation = try await agent.runStructured(
    "Recommend a sci-fi movie from the last 10 years that explores AI consciousness."
)

print("Title:      \(movie.title) (\(movie.year))")
print("Genre:      \(movie.genre)")
print("Rating:     \(movie.rating)/10")
print("Reason:     \(movie.reason)")
print("Streaming:  \(movie.streamingOn.joined(separator: ", "))")
print("Similar:    \(movie.similarMovies.joined(separator: ", "))")
