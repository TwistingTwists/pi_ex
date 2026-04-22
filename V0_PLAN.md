# PiEx v0 — Implementation Plan

## Goal
A working agent loop that can: receive a prompt, call an LLM (or fake), execute tools (read/write/edit/bash), feed results back, and repeat until done. Process per session, Ash resources for data, no persistence yet.

## Architecture

```
PiEx.Application
├── Registry (:pi_ex_registry)           # subscriber lookup
├── DynamicSupervisor (:pi_ex_sessions)  # supervises agents
│   └── PiEx.Agent (GenServer)           # one per session
│       ├── Task (LLM streaming)         # linked, dies with parent  
│       └── Task.Supervisor children     # tool execution
```

## Work Packages (4 parallel tracks)

### WP1: Ash Domain + Resources (no deps on other WPs)
Files: `lib/pi_ex/chat.ex`, `lib/pi_ex/chat/*.ex`

- `PiEx.Chat` — Ash domain
- `PiEx.Chat.Message` — embedded resource, roles: user/assistant/tool_result
  - Uses `ReqLLM.Message` and `ReqLLM.Message.ContentPart` for LLM-compatible content
  - Adds our own fields: `id`, `timestamp`, `stop_reason`, `usage`, `error_message`
  - Actions: `create_user`, `create_assistant`, `create_tool_result`
- `PiEx.Chat.ToolCall` — embedded resource for tool invocations within assistant messages
  - Fields: `id`, `name`, `arguments`
- Tests: create each message type, validate constraints

### WP2: Tool Behaviour + 4 Built-in Tools (no deps on other WPs)
Files: `lib/pi_ex/tool.ex`, `lib/pi_ex/tools/*.ex`

- `PiEx.Tool` — behaviour: `@callback name/0`, `description/0`, `parameters/0`, `execute/2`
  - `execute(args, context)` returns `{:ok, content}` or `{:error, reason}`
  - context is `%{cwd: String.t()}`
  - content is `[%{type: :text, text: String.t()}]` (list of content parts)
- `PiEx.Tools.Read` — read file, offset/limit, truncation (2000 lines / 50KB)
- `PiEx.Tools.Write` — write file, create parent dirs
- `PiEx.Tools.Edit` — exact text replacement, multiple edits, uniqueness check
- `PiEx.Tools.Bash` — execute command, timeout, output truncation
- `PiEx.Tools` — `coding_tools/0` returns all 4 as `ReqLLM.Tool` structs
- Tests: each tool against tmp_dir fixtures

### WP3: Turn Logic — Pure Functions (depends on WP1 types + WP2 behaviour, but can stub)
Files: `lib/pi_ex/turn.ex`

- `PiEx.Turn.build_request/3` — `(messages, system_prompt, tools)` → map for req_llm
  - Filters messages to LLM-compatible roles (strips custom)
  - Converts PiEx messages to `ReqLLM.Message` structs
  - Converts tools to `ReqLLM.Tool` format
- `PiEx.Turn.extract_tool_calls/1` — from assistant response, return list of tool calls
- `PiEx.Turn.execute_tools/3` — `(tool_calls, tool_map, context)` → list of tool result messages
  - Parallel via `Task.async_stream`
  - Wraps errors, returns `PiEx.Chat.Message` tool_result for each
- `PiEx.Turn.next_action/1` — given assistant message, return `:continue | :done | :error`
- Tests: with hand-built message structs, no LLM needed

### WP4: Agent GenServer + Supervision (depends on WP1-3 interfaces, can stub)
Files: `lib/pi_ex/agent.ex`, `lib/pi_ex/application.ex`

- `PiEx.Agent` — GenServer with states: `:idle`, `:streaming`, `:executing_tools`
  - `start_link/1` opts: `stream_fn`, `tools`, `system_prompt`, `model`, `cwd`
  - `prompt/2` — cast, rejected if not idle
  - `steer/2` — cast, queued in state
  - `abort/1` — cast, kills active task
  - `subscribe/1` — caller pid added to subscribers
  - `get_state/1` — sync call, returns messages/status
  - Internal: spawns Task for LLM call, receives chunks, broadcasts events
  - After LLM done: extract tool calls → execute → if tools ran, loop (send self :continue)
  - Between turns: check steering queue, inject if present
- `PiEx.Application` — start Registry + DynamicSupervisor
- `PiEx` — public API facade: `start_session/1`, `prompt/2`, `steer/2`, `abort/1`, `subscribe/1`
- Tests: with fake stream_fn, verify event sequence and tool execution loop

## Dependency Graph

```
WP1 (Ash Resources) ──┐
                       ├──► WP3 (Turn Logic) ──► WP4 (Agent GenServer)
WP2 (Tools)          ──┘
```

WP1 and WP2 are fully independent → parallel.
WP3 needs WP1+WP2 types but can be started with stubs.
WP4 needs WP3 but can be started with stubs.

## Dispatch Strategy

**Phase A (parallel):** WP1 + WP2 simultaneously
**Phase B (after A):** WP3 + WP4 (WP4 can start slightly after WP3)

Since WP3 and WP4 both need the types from WP1/WP2, we run Phase A first, verify compilation, then dispatch Phase B.

## Stream Function Contract

The `stream_fn` is the key abstraction for testability:

```elixir
@type stream_fn :: (request :: map(), opts :: keyword() -> 
  {:ok, ReqLLM.StreamResponse.t()} | {:ok, ReqLLM.Response.t()} | {:error, term()})
```

For testing, a fake that returns canned responses.
For production, wraps `ReqLLM.Generation.stream_text/3`.

## Event Types (plain structs, not Ash — they're transient)

```elixir
# All events are maps with :type key
%{type: :agent_start}
%{type: :agent_end, messages: [...]}
%{type: :turn_start}
%{type: :turn_end, message: msg, tool_results: [...]}
%{type: :message_start, message: msg}
%{type: :message_delta, delta: "text chunk"}
%{type: :message_end, message: msg}
%{type: :tool_start, tool_name: "read", args: %{}}
%{type: :tool_end, tool_name: "read", result: ..., error?: false}
```

Delivered as `send(subscriber, {:pi_ex, session_id, event})`.

## Success Criteria

1. `mix test` passes
2. Can start a session with fake stream_fn, prompt it, get events back
3. Tools execute against real filesystem in tmp_dir
4. Tool results feed back into context, agent loops until no more tool calls
5. Steering messages inject between turns
6. Abort kills the streaming task
