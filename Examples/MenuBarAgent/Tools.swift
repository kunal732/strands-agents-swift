import Foundation
import StrandsAgents

let demoTools: [any AgentTool] = [
    FunctionTool(
        name: "get_weather",
        description: "Get the current weather for a city",
        inputSchema: [
            "type": "object",
            "properties": [
                "city": ["type": "string", "description": "City name"],
            ],
            "required": ["city"],
        ]
    ) { input, _ in
        let city = input["city"]?.foundationValue as? String ?? "unknown"
        let conditions = ["sunny", "partly cloudy", "overcast", "light rain", "clear skies"]
        let temp = Int.random(in: 45...95)
        return "\(city): \(temp) F, \(conditions.randomElement()!)"
    },

    FunctionTool(
        name: "calculator",
        description: "Evaluate a math expression",
        inputSchema: [
            "type": "object",
            "properties": [
                "expression": ["type": "string", "description": "Math expression to evaluate"],
            ],
            "required": ["expression"],
        ]
    ) { input, _ in
        let expr = input["expression"]?.foundationValue as? String ?? "0"
        if let result = NSExpression(format: expr).expressionValue(with: nil, context: nil) {
            return "\(result)"
        }
        return "Could not evaluate: \(expr)"
    },

    FunctionTool(
        name: "get_time",
        description: "Get the current date and time",
        inputSchema: ["type": "object"]
    ) { _, _ in
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    },

    FunctionTool(
        name: "take_note",
        description: "Save a note for later reference",
        inputSchema: [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Note title"],
                "content": ["type": "string", "description": "Note content"],
            ],
            "required": ["title", "content"],
        ]
    ) { input, _ in
        let title = input["title"]?.foundationValue as? String ?? ""
        return "Note saved: \(title)"
    },
]
