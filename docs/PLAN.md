# PiEx — Implementation Plan

An Elixir agentic library inspired by [pi-mono](https://github.com/badlogic/pi-mono). Headless SDK, process-per-session, JSONL/SQLite persistence, powered by `req_llm`.

## Key Patterns Distilled from pi-mono

### 1. Agent Loop (pi-agent-core)
The heart of pi is a tight loop: **prompt → LLM call → tool execution → repeat until no tool calls remain**. It handles:
- Streaming token-by-token via event callbacks
- Parallel or sequential tool execution per turn
- Steering messages (inject mid-run) and follow-up messages (inject when agent would stop)
- `beforeToolCall` / `afterToolCall` hooks for interception, blocking, or mutation
- Abort via signal at any point

### 2. Minimal Default Tools
Four tools ship by default: `read`, `write`, `edit`, `bash`. They're defined as data (schema + execute function), not baked into the loop. Users swap in their own tools trivially.

### 3. Session as Persistent Tree
Sessions are JSONL append-only logs with `id`/`parentId` linking. This gives:
- Branching (fork from any point)
- Compaction (summarize old context, keep working)
- Resume across restarts

### 4. Events Everywhere
Every lifecycle moment emits an event: `agent_start`, `turn_start`, `message_update` (streaming deltas), `tool_execution_start/update/end`, `agent_end`. Consumers subscribe and react — TUI, logging, persistence, extensions all use the same event stream.

### 5. System Prompt Construction
The system prompt is assembled from parts: base instructions, tool descriptions, guidelines (derived from which tools are active), context files (AGENTS.md walked up from cwd), and skills. This is composable, not monolithic.

### 6. Message Abstraction
`AgentMessage` is a union: standard LLM messages (user/assistant/tool-result) + custom app messages. A `convertToLlm` function strips custom messages before sending to the model. This lets the session carry rich state without polluting the LLM context.

### 7. Resource Loader
A pluggable `ResourceLoader` discovers and provides extensions, skills, prompts, themes, context files. `DefaultResourceLoader` does filesystem discovery; you can replace it entirely for embedded use.

### 8. Config Layering
Settings merge: global (`~/.pi/agent/settings.json`) → project (`.pi/settings.json`) → runtime overrides. Same pattern for API keys: env vars → stored credentials → runtime overrides.

---

## Architecture for PiEx

```
pi_ex/
├── lib/
│   ├── pi_ex.ex                    # Public API facade
│   ├── pi_ex/
│   │   ├── application.ex          # OTP app (Registry, DynamicSupervisor)
│   │   ├── agent.ex                # GenServer — the agent loop (1 process per session)
│   │   ├── agent_loop.ex           # Pure function: run one turn (LLM call → tool exec → events)
│   │   ├── tool.ex                 # Tool behaviour + built-in tools
│   │   ├── tools/
│   │   │   ├── read.ex
│   │   │   ├── write.ex
│   │   │   ├── edit.ex
│   │   │   └── bash.ex
│   │   ├── message.ex              # AgentMessage types + convertToLlm
│   │   ├── event.ex                # Event types + PubSub helpers
│   │   ├── session.ex              # Session behaviour (persistence contract)
│   │   ├── session/
│   │   │   ├── jsonl.ex            # JSONL append-only session store
│   │   │   └── memory.ex           # In-memory session (for testing)
│   │   ├── system_prompt.ex        # Composable system prompt builder
│   │   └── config.ex               # Settings loading + layered merge
│   └── ...
├── test/
├── mix.exs
└── PLAN.md
```

## Implementation Phases

### Phase 1 — Core Loop + Types
- [ ] `PiEx.Message` — message types (user, assistant, tool_call, tool_result, custom)
- [ ] `PiEx.Event` — event types as structs
- [ ] `PiEx.Tool` — behaviour: `name/0`, `description/0`, `parameters/0`, `execute/3`
- [ ] `PiEx.AgentLoop` — pure function: given (messages, tools, system_prompt, stream_fn) → run one turn, emit events, return updated messages
- [ ] `PiEx.Agent` — GenServer wrapping the loop. Holds state (messages, tools, model, system_prompt). Exposes `prompt/2`, `steer/2`, `abort/1`. Publishes events via `Registry`.

### Phase 2 — LLM Integration via req_llm
- [ ] `PiEx.LLM` — adapter: takes model config + messages → calls `req_llm` → streams back assistant message events
- [ ] Support Anthropic, OpenAI, Google out of the box (req_llm handles the wire protocol)
- [ ] Token-by-token streaming via req_llm's streaming support → mapped to `PiEx.Event` structs

### Phase 3 — Built-in Tools
- [ ] `PiEx.Tools.Read` — read file contents (text + images), offset/limit for large files
- [ ] `PiEx.Tools.Write` — create/overwrite files, auto-create parent dirs
- [ ] `PiEx.Tools.Edit` — exact text replacement with multiple edits, uniqueness validation
- [ ] `PiEx.Tools.Bash` — execute shell commands, timeout, output truncation

### Phase 4 — Session Persistence
- [ ] `PiEx.Session` behaviour — `append/2`, `entries/1`, `get_path/1`, `branch/2`
- [ ] `PiEx.Session.Memory` — ETS-backed, for tests and ephemeral use
- [ ] `PiEx.Session.JSONL` — append-only file, tree structure with id/parentId
- [ ] Optional: `PiEx.Session.SQLite` via `exqlite` — same tree model, queryable

### Phase 5 — System Prompt + Config
- [ ] `PiEx.SystemPrompt` — composable builder: base + tools + guidelines + context files
- [ ] `PiEx.Config` — layered settings (global → project → runtime)
- [ ] Context file discovery (walk up from cwd looking for `AGENTS.md`)

### Phase 6 — Hooks + Interception
- [ ] `before_tool_call` / `after_tool_call` hooks on the Agent
- [ ] Tool call blocking (return `{:block, reason}`)
- [ ] Tool result mutation (return modified content/details)

## Public API (Target)

```elixir
# Start a session
{:ok, pid} = PiEx.start_session(
  model: {:anthropic, "claude-sonnet-4-20250514"},
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  tools: PiEx.Tools.coding_tools(),
  system_prompt: "You are a helpful coding assistant.",
  session: PiEx.Session.JSONL.new("./sessions/my-session.jsonl")
)

# Subscribe to events
PiEx.subscribe(pid)

# Send a prompt
PiEx.prompt(pid, "What files are in the current directory?")

# Receive streaming events
receive do
  {:pi_ex_event, %PiEx.Event.MessageUpdate{delta: delta}} ->
    IO.write(delta)
  {:pi_ex_event, %PiEx.Event.AgentEnd{messages: messages}} ->
    IO.puts("\nDone. #{length(messages)} new messages.")
end

# Steer mid-run
PiEx.steer(pid, "Actually, focus on .ex files only")

# Abort
PiEx.abort(pid)
```

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Process model | GenServer per session | Natural Elixir isolation, crash recovery, concurrent sessions |
| Event delivery | Registry-based PubSub | Lightweight, no external deps, process-local |
| LLM client | req_llm | Composable, multi-provider, streaming built-in |
| Tool definition | Behaviour + struct | Pattern-matchable, easy to test, swappable |
| Session format | JSONL (primary), SQLite (optional) | JSONL is simple and append-only like pi-mono; SQLite for queryability |
| Message types | Tagged structs | Elixir-idiomatic, pattern-matchable vs pi's TypeScript union types |
| Streaming | GenServer → Registry → subscriber processes | Back-pressure via process mailbox, no GenStage overhead for this use case |

## Non-Goals (for now)
- TUI / CLI interface
- Skills & extensions system
- Prompt templates
- Compaction (context window management)
- OAuth / subscription auth flows
- Package management
