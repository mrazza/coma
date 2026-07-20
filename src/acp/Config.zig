const std = @import("std");
const Provider = @import("llm").Provider;
const SessionConfig = @import("agent").types.SessionConfig;

const Config = @This();

provider: Provider,
default_session_config: SessionConfig,
