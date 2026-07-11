# COMA: Comptime Agent

An LLM agent architecture written entirely in native Zig.

![screenshot](shot.png)

## The 'Why'

First and foremost, this project was built as a hands-on way to learn Zig. I wanted a project where I couldn't just slide by on basic syntax but also wasn't so complex it would take forever to get working. Building an LLM agent framework fit the bill. An agent has to deal with nested dynamic JSON, HTTP connections, and complex memory lifetimes—forcing me to jump straight into the deep end of how Zig handles memory and compile-time evaluation.

Sure, writing LLM agent loops is a solved problem and it's completely unnecessary to do this in Zig... but it was fun to figure out and it runs incredibly fast.

## Core Features

- **Type-safe Comptime Tool Registration**: This is the coolest part of the project. Using Zig's compile-time reflection (`comptime`), you can register standard Zig functions as agent tools. The compiler checks that your function parameters match the tool's descriptor structure, so you don't have to write boring boilerplates to parse arguments from JSON.
- **Incremental Streaming & Response Accumulator**: Built-in support for streaming model responses (including thinking steps, markdown text, and tool calls) chunk-by-chunk.
- **Asynchronous & Concurrent Tool Execution**: Built on top of Zig's native non-blocking I/O event loop (`std.Io`). Instead of running tool calls sequentially, the Agent uses `Io.Select` to kick off independent tool calls concurrently and await their results asynchronously.
- **Async Zero-Dependency HTTP/Client Stack**: COMA handles communication with LLM backends asynchronously using Zig's native `std.http.Client` integrated with the `std.Io` event loop. No external libraries needed.
- **Explicit Memory Control**: Everything uses Zig's explicit allocator pattern. You can run the agent loop under an `ArenaAllocator` or manage the lifetime of prompt histories and intermediate tool results manually.

## Setup

COMA is tested and built with **Zig 0.16.0**.

### 1. Configure the API Key
Get an API key from Google AI Studio. You can set it in your environment:

```bash
export GEMINI_API_KEY="your-api-key"
```

Or create a `.env` file in the root of the project:

```bash
GEMINI_API_KEY="your-api-key"
```

### 2. Run the Interactive Chat
To build and start the CLI agent interface:

```bash
zig build run
```

### 3. Run the Test Suite
To compile and execute all mock provider and agent tests:

```bash
zig build test
```

## The Roadmap / Future Plans

Here's what is planned next:
- **ACP Server Integration**: Build an ACP (Agent Connection Protocol) server directly into the agent. This will allow the agent to connect to external frontends, such as the [goose-mm-bridge](https://github.com/mrazza/goose-mm-bridge) ACP connector.
- **Agents.md, SKILLS, etc**: Add support for agents, skills, and tools defined in markdown with RAG-style retrieval.
- **More Providers**: Add support for Anthropic (Claude) and OpenAI, as well as local Ollama instances.
- **Vector DB Client / Long-Term Memory**: A simple native Zig client for a vector database (or just a local SQLite database) to give the agent persistent memory across runs.

