# COMA: Comptime Agent

An LLM agent architecture written entirely in native Zig.

![screenshot](shot.png)

## The 'Why'

First and foremost, this project was built as a hands-on way to learn Zig. I wanted a project where I couldn't just slide by on basic syntax but also wasn't so complex it would take forever to get working. Building an LLM agent framework fit the bill. An agent has to deal with nested dynamic JSON, HTTP connections, and complex memory lifetimes—forcing me to jump straight into the deep end of how Zig handles memory and compile-time evaluation.

Sure, writing LLM agent loops is a solved problem and it's completely unnecessary to do this in Zig... but it was fun to figure out and it runs incredibly fast.

## Core Features

- **Type-safe Comptime Tool Registration**: Register standard Zig functions as agent tools. The compiler checks that your function parameters match the tool's descriptor structure using Zig's compile-time reflection.
- **Incremental Streaming & Response Accumulator**: Built-in support for streaming model responses chunk-by-chunk.
- **Asynchronous & Concurrent Tool Execution**: Built on top of Zig's native non-blocking I/O event loop (`std.Io`). Instead of running tool calls sequentially, the Agent uses `Io.Select` to kick off independent tool calls concurrently and await their results asynchronously.
- **Async Zero-Dependency HTTP/Client Stack**: Communication with LLM backends asynchronously using Zig's native `std.http.Client`.
- **Explicit Memory Control**: Everything uses Zig's explicit allocator pattern. The running application consumes ~5MB of memory.

## Tool Registration Example

COMA uses Zig's `comptime` capabilities to make tool registration type-safe and boilerplate-free.

```zig
// Define a standard Zig function
fn getWeather(allocator: std.mem.Allocator, zip_code: i64) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "Weather in {d}: Sunny, 72°F", .{zip_code});
}

// Register it with the Agent
const weather_tool = Tool.init(.{
    .name = "get_weather",
    .description = "Get the current weather for a given zip code.",
    .parameters = &.{
        .{
            .name = "zip_code",
            .type = .integer,
            .required = true,
            .description = "The 5-digit zip code.",
        },
    },
}, getWeather);
```

## Library Usage

To use COMA in your own project, initialize a provider and the agent loop:

```zig
var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
var gemini_client = try provider.Gemini.init(allocator, &http_client, api_key);
var client = gemini_client.provider();

const agent_config: types.AgentConfig = .{
    .model = selected_model,
    .tools = &[_]Tool{ weather_tool },
};

var agent = try Agent.init(allocator, io, client, agent_config);
defer agent.deinit();

const result = try agent.executeTurn(.{ .prompt = "What is the weather in 90210?" });
```

## Project Structure

- `src/agent/`: Core agent logic, tool execution, and type definitions.
- `src/llm/`: Generic LLM provider interfaces and message schemas.
- `src/provider/`: Concrete implementations for LLM services (e.g., Google Gemini).
- `src/testing/`: Mocks and utilities for testing the agent without network calls.
- `src/main.zig`: The CLI entry point and interactive chat interface.

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

- **ACP Server Integration**: Build an ACP (Agent Connection Protocol) server directly into the agent. This will allow the external frontends, such as the [goose-mm-bridge](https://github.com/mrazza/goose-mm-bridge), to control the agent.
- **Agents.md / SKILLS**: Define agent behaviors in Markdown files and load them into context automatically.
- **More Providers**: Support for Anthropic, OpenAI, Ollama, etc.
- **Vector DB Client**: Persistent long-term memory.

## License

Distributed under the Apache License 2.0. See `LICENSE` for more information.
