# Samples

Standalone examples from simple to complex. Each is a single `main.swift` you can read top to bottom.

| # | Sample | Provider | What it shows |
|---|--------|----------|---------------|
| 01 | SimpleLocalAgent | MLX (on-device) | `@Tool` macro, streaming, word count |
| 02 | SimpleBedrockAgent | AWS Bedrock | Cloud agent with calculator tool |
| 03 | HybridAgent | MLX + Bedrock | `HybridRouter`, `RoutingHints`, privacy routing |
| 04 | NovaSonicBidi | AWS Nova Sonic | Real-time voice agent (cloud) |
| 05 | MLXBidiLocal | MLX Audio | Fully on-device voice (STT + LLM + TTS) |
| 06 | MultiAgentGraph | Bedrock | Parallel analysis agents + editor synthesis |
| 07 | MultiAgentSwarm | Bedrock | Coordinator routes to calendar/notes/tasks agents |
| 08 | MultiProvider | Anthropic + OpenAI + Gemini | Same tool across three providers |

## Running

These are not registered as Swift Package Manager executable targets (to avoid pulling all dependencies for every sample). To run one:

```bash
# Local inference (no credentials needed)
cd 01-SimpleLocalAgent
swift run -c release

# Bedrock (requires AWS credentials)
export AWS_PROFILE=your-profile
export AWS_DEFAULT_REGION=us-east-1
cd 02-SimpleBedrockAgent
swift run

# Multi-provider (requires API keys)
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export GOOGLE_API_KEY=AIza...
cd 08-MultiProvider
swift run
```

For MLX samples (01, 03, 05), use `xcodebuild` or open in Xcode. Metal library loading fails with `swift run`.
