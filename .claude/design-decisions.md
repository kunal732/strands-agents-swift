# Design Decisions & Anti-Regression Guide
**Generated:** 2026-03-17 17:56
**Project:** /Users/kunal.batra/Documents/code/datadog/strands/sdk-swift
**Session:** 38f24474-7947-434f-85d8-25c9698c5736
**Compaction trigger:** manual

Design Decisions & Anti-Regression Guide updated. Key additions from this session:

**New rejected approaches logged:**
- Weather API example (too much code, buried the concept)
- Showing only macro without manual `AgentTool` alternative
- Using different tool examples across README sections
- Recommending manual `AgentTool` as primary path

**New key decisions logged:**
- Tools section structure: macro first, manual second, both using `wordCount`
- Intro framing: "The Swift implementation of Strands Agents SDK uses a @Tool macro..."
- `wordCount` as the single canonical example throughout the entire README

**New DO-NOTs logged:**
- Don't use different tool examples in different sections
- Don't drop the specific intro framing the user requested
- Don't recommend manual `AgentTool` as the default