# Writing Assistant

Multi-agent graph demo: three agents analyze a draft in parallel (grammar, tone, clarity), then an editor synthesizes their feedback.

## Running

SwiftPM executable targets cannot produce macOS `.app` bundles. To run this example:

1. In Xcode: **File > New > Project > macOS > App**
2. Name it `WritingAssistant`, select Swift + SwiftUI
3. **File > Add Package Dependencies** -- add `https://github.com/kunal732/strands-agents-swift`
4. Add `StrandsAgents` and `StrandsBedrockProvider` to the target
5. Delete the generated `ContentView.swift` and `WritingAssistantApp.swift`
6. Drag all `.swift` files from this folder into the Xcode project
7. In `main.swift`, remove the `main.swift` file and rename `WritingAssistantApp.swift` to be your `@main` entry -- or just use these files as-is with `main.swift`
8. Press **Cmd+R**

Requires AWS credentials configured (`~/.aws/credentials` or environment variables).
