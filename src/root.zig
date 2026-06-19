const std = @import("std");
const llm = @import("llm");
const provider = @import("provider");

test "compile llm module" {
    _ = llm.Provider;
    _ = llm.types.SessionConfig;
}

test "compile providers module" {
    _ = provider.Gemini;
    std.testing.refAllDecls(provider);
}
